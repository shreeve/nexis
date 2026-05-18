//! vm.zig — Phase 2 VM kernel.
//!
//! Authoritative spec: `docs/VM.md`. Adapted from `../em/src/{bytecode,
//! runtime}.zig` per the user's latitude to lift + modify em freely.
//!
//! **Currently implemented** (COMPILER.md §10 steps #1–#2):
//!
//!   - 64-bit instruction encoding + operand packing (VM.md §3, §4).
//!   - `Routine` (compiled code + constants; plain Zig struct,
//!     not a heap Value yet — heap-kind promotion lands with
//!     closures per VM.md §5 staged-realization note).
//!   - `Frame` (base_slot + slot_count + pc + routine pointer)
//!     windowing into a VM-shared backing `stack: ArrayList(Value)`
//!     per VM.md §7 (peer-AI turn 40 backing-stack model). Frames
//!     live in `frames: ArrayList(Frame)`; step 5a0 still has
//!     exactly one frame at runtime, but the storage model is
//!     ready for `call:call` / `call:tailcall` (step 5a1) without
//!     a second restructuring.
//!   - `VM` with two-level-switch dispatch. Tail-call-threaded
//!     upgrade is deferred per VM.md §8 staged-realization note.
//!   - 6 opcodes wired across 3 groups:
//!       mov: load-const, move, load-nil, load-true, load-false
//!       call: return, return-nil
//!       math: add (fixnum+fixnum, traps overflow as IntegerOverflow,
//!             traps non-fixnum as KindMismatch)
//!   - Hand-assembled bytecode tests. The `src/compile.zig` tiny
//!     compiler lowers `(+ 1 2)`-style forms directly to math:add
//!     bytecode and the `Tiny` form representation.
//!
//! What's NOT here yet (deferred per COMPILER.md §10):
//!
//!   - `call:call` / `call:tailcall` — step #5 (range-call ABI per
//!     VM.md §6 amendment). Requires the multi-frame backing-stack
//!     evolution noted in VM.md §7.
//!   - `closure:*` group (`make`, `box-local`, `new-cell`,
//!     `init-cell`, `get-cell`) — step #5.
//!   - `jump:*` group + `if` lowering — step #3.
//!   - `cmp:*` group — step #3.
//!   - `var:*` group + `def` lowering — step #7.
//!   - `coll:*` / `transient:*` / `hash:*` groups — Phase 2 mid-late.
//!   - `ctrl:*` (try/catch/throw) — step #9.
//!   - `tx:*` group — Phase 4.
//!   - `simd:*` group — Phase 6.
//!   - GC root enumeration from frames — lands when the multi-frame
//!     stack does.
//!
//! Implementation sequence (COMPILER.md §10):
//!   1. VM kernel skeleton (mov, call:return)            ✓ done
//!   2. Tiny compiler for (+ 1 2) + math:add             ✓ done
//!   3. Conditionals (jump:*, if lowering)               ← next
//!   4. Locals + let*
//!   5. Functions + closures (range-call ABI + closure:*)
//!   6. recur + loop* (with captured-binding fresh cells per VM.md §6)
//!   7. Vars + def
//!   8. Macroexpand + syntax-quote + #%anon-fn
//!   9. try/catch/throw
//!  10. Error-reporting hardening
//!  11. Golden + eval tests

const std = @import("std");
const value_mod = @import("value");
/// Step 5e (peer-AI turn 49 Option D): the VM owns a `Heap`
/// backed by `runtime_arena` for constructing rest-arg lists
/// at variadic call sites. heap + list are pure-allocator
/// modules; pulling them in does NOT pull GC. The Heap shares
/// the closure/cell allocator so all VM-side runtime values
/// are freed together at `VM.deinit`.
const heap_mod = @import("heap");
const list_mod = @import("list");
/// Step #8c.3: persistent vector for `coll:vector` opcode +
/// runtime vector construction (the `(#%vector ...)` IR).
/// Like list_mod, vector_mod is a pure-allocator wrapper —
/// no GC dependency.
const vector_mod = @import("vector");
/// Phase 3.1: persistent map/set (CHAMP) for `coll:map` /
/// `coll:set` opcodes. Map/set construction requires hash +
/// equality, so we also pull in dispatch_mod (the canonical
/// hashValue + equal entry points per dispatch.zig docs).
const champ_mod = @import("champ");
const dispatch_mod = @import("dispatch");
/// Step E1 (pre-#8 macroexpander prereq, peer-AI turn 55):
/// the VM owns an `Interner` used by the Form-lowering layer
/// to convert quoted symbols/keywords into stable `Value`s. The
/// macroexpander (step #8) will use the same Interner for
/// auto-gensym + syntax-quote output. Single shared Interner
/// means symbol/keyword Value identity is consistent across the
/// whole VM lifetime.
const intern_mod = @import("intern");
const Value = value_mod.Value;

// =============================================================================
// Instruction encoding (VM.md §3 + §4)
//
// Primary instruction: 64 bits
//   [kind:4][group:6][variant:6][opA:16][opB:16][opC:16]
//
// Each operand is 16 bits: [kind:4][index:12].
//
// Packed structs keep the Zig layout byte-exact across platforms.
// =============================================================================

pub const OpKind = enum(u4) {
    /// S — frame-local slot.
    slot = 0,
    /// C — routine's constant pool.
    constant = 1,
    /// V — namespace Var. Not exercised until the `var` group lands.
    var_ = 2,
    /// U — closure upvalue. Not exercised until closures land.
    upvalue = 3,
    /// I — intern id (keyword/symbol). Not exercised yet.
    intern = 4,
    /// J — bytecode offset (jump target). Used by `jump:*` group.
    jump = 5,
    /// E — durable ref literal. Phase 4 (`tx:*`).
    durable = 6,
    // 7..14 reserved.
    /// Sentinel for "no operand".
    unused = 15,
    /// Non-exhaustive marker: bytecode from a future nexis may
    /// use operand kinds this VM doesn't recognize. Dispatch code
    /// catches those via `_` prong and surfaces BytecodeCorruption.
    _,
};

pub const Operand = packed struct(u16) {
    kind: OpKind,
    index: u12,

    pub const none: Operand = .{ .kind = .unused, .index = 0 };

    pub fn slot(i: u12) Operand {
        return .{ .kind = .slot, .index = i };
    }
    pub fn constant(i: u12) Operand {
        return .{ .kind = .constant, .index = i };
    }
    pub fn jump(i: u12) Operand {
        return .{ .kind = .jump, .index = i };
    }

    pub fn upvalue(i: u12) Operand {
        return .{ .kind = .upvalue, .index = i };
    }

    /// Step #6a: V-kind operand referencing
    /// `routine.var_table[i]`.
    pub fn varRef(i: u12) Operand {
        return .{ .kind = .var_, .index = i };
    }
};

/// Instruction kind discriminator — primary vs extension (per PLAN
/// §12.1). Extension packs 20-bit operand indices for programs that
/// exceed the 12-bit primary-operand range. Extension is NOT
/// implemented in this commit — the `ext` encoding remains reserved.
pub const InstKind = enum(u4) {
    primary = 0,
    extension = 1,
    _,
};

/// Opcode group (6 bits). Full v1 taxonomy per PLAN §12.3 and
/// VM.md §10. Only `mov` and `call` have implemented variants in
/// this commit.
pub const Group = enum(u6) {
    jump = 0,
    cmp = 1,
    math = 2,
    mov = 3,
    call = 4,
    closure = 5,
    var_ = 6,
    coll = 7,
    transient = 8,
    hash = 9,
    tx = 10,
    ctrl = 11,
    io = 12,
    simd = 13,
    _,
};

/// Variants for the `mov` group. Extends as the compiler grows.
pub const Mov = enum(u6) {
    move = 0,
    load_const = 1,
    load_nil = 2,
    load_true = 3,
    load_false = 4,
    // load_fixnum_inline, load_keyword, load_symbol — later.
    _,
};

/// Variants for the `call` group.
pub const Call = enum(u6) {
    call = 0,
    tailcall = 1,
    @"return" = 2,
    return_nil = 3,
    // apply, invoke_var — later.
    _,
};

/// Variants for the `closure` group. Per VM.md §10.4. Step 5a1
/// wires `make` only (with empty descriptors); 5b adds the cell
/// access ops, 5c adds the placeholder-cell ops.
pub const Closure_ = enum(u6) {
    make = 0,
    box_local = 1,
    new_cell = 2,
    init_cell = 3,
    get_cell = 4,
    _,
};

/// Variants for the `jump` group. Per PLAN §12.3 / VM.md §10.5.
/// Step #3 (COMPILER.md §10 #3) wires all three v1 variants —
/// they're tiny and `if-true` pairs naturally with `if-false`
/// (the analyzer chooses whichever produces shorter code per
/// branch direction).
pub const Jump = enum(u6) {
    jmp = 0,
    if_true = 1,
    if_false = 2,
    _,
};

/// Variants for the `coll` group. Per VM.md §10 group #7
/// (reserved for collection construction/access ops).
///
/// Step #8c.1: `list` and `concat` land as the runtime
/// substrate for syntax-quote's `(#%list ...)` / `(#%concat ...)`
/// output. Both take a slot-block (A=base, B=argc, C=dst) and
/// build an immutable List Value via `VM.heap` (arena-backed
/// for Phase 2; GC-traced in Phase 4 — peer-AI turn 58 §D3
/// flagged the rooting TODO for the eventual GC integration).
/// Variants for the `ctrl` group. Per VM.md §10 group #11 +
/// §12 try/catch/throw spec.
///
/// Step #9.1 (peer-AI turn 59): try-enter / try-exit / throw
/// land. `finally-exit` reserved (variant 2) — used by #9.2
/// once finally support comes in.
///
/// `halt` variant (5) explicitly unused — the existing
/// top-level `call:return` path already halts the VM (per
/// peer-AI turn 59 §D10). Uncaught throw halts via
/// `VmError.UncaughtThrow`.
pub const CtrlOp = enum(u6) {
    /// `ctrl:try-enter A=catch_pc B=binding_slot C=unused` —
    /// push a try handler. catch_pc is absolute. binding_slot
    /// is where the thrown value will be stored when the catch
    /// fires. C is reserved for the finally_pc operand in #9.2;
    /// MUST be `.unused` kind in #9.1.
    try_enter = 0,
    /// `ctrl:try-exit A=post_pc B=unused C=unused` — pop the
    /// current handler/cleanup (must belong to this frame) and
    /// jump to post_pc. In #9.2, if the popped handler has a
    /// finally_pc, the VM redirects through the finally body
    /// with a saved post_pc continuation.
    try_exit = 1,
    /// `ctrl:finally-exit` — reserved for #9.2.
    finally_exit = 2,
    /// `ctrl:throw A=value_operand B=unused C=unused` — throw
    /// the resolved value. A may be any operand kind (slot,
    /// constant, var). Walks the handler stack; if a try
    /// handler matches, replaces it with a cleanup handler
    /// (peer-AI turn 59 §D5 "classic trap": prevents the
    /// catch body from being re-caught by its own handler),
    /// binds the thrown value, and jumps to catch_pc. If no
    /// handler matches in any frame, halts with
    /// `VmError.UncaughtThrow`.
    throw_ = 3,
    /// Reserved.
    halt_ = 5,
    _,
};

pub const CollOp = enum(u6) {
    /// `coll:list A=arg_base B=argc C=dst` — build a list from
    /// argc consecutive slots starting at A. Empty list (argc=0)
    /// is the canonical empty value per `list_mod.empty(heap)`.
    list = 0,
    /// `coll:concat A=arg_base B=argc C=dst` — each arg slot
    /// must hold a list Value; result is the left-to-right
    /// concatenation. Empty concat (argc=0) returns the empty
    /// list. Non-list arg traps `KindMismatch`.
    concat = 1,
    /// Step #8c.3: `coll:vector A=arg_base B=argc C=dst` —
    /// build a persistent vector from argc consecutive slots.
    /// Empty vector (argc=0) via `vector_mod.empty(heap)`.
    /// Allocates via `vector_mod.fromSlice` for argc>0.
    vector = 2,
    /// Phase 3.1: `coll:map A=arg_base B=argc C=dst` — build
    /// a persistent map from argc slots interpreted as flat
    /// k,v,k,v,... pairs. argc MUST be even
    /// (BytecodeCorruption otherwise — compiler guarantees
    /// this). Duplicate keys: later wins (Clojure semantics).
    /// Hash + equality come from dispatch.hashValue +
    /// dispatch.equal.
    map = 3,
    /// Phase 3.1: `coll:set A=arg_base B=argc C=dst` — build
    /// a persistent set from argc slot values. Duplicates
    /// collapse (set semantics). Same hash/eq machinery as
    /// `coll:map`.
    set = 4,
    _,
};

/// Variants for the `var` group. Per VM.md §10 group #6.
/// #6a wires `load_var`; #6b adds `store_var` and `var_object`.
pub const VarOp = enum(u6) {
    /// Load the Var's root value into a slot. Traps :unbound-var.
    load_var = 0,
    /// Set the Var's root, mark bound, return the Var object.
    store_var = 1,
    /// Load the Var object itself (not its value) into a slot.
    /// Does NOT trap on unbound — taking a reference to an
    /// unbound Var is legal.
    var_object = 2,
    _,
};

/// Variants for the `cmp` group. Per VM.md §10 group #1 (peer-AI
/// turn 47 — comparisons live in their own group, NOT in `math`,
/// to keep arithmetic ISA clean). Step 5d0 wires `lt` only —
/// the minimum needed to write a terminating loop test for
/// `recur` / `loop*`. The remaining variants are listed here so
/// dispatch can distinguish "known but not wired" from
/// "unrecognized bit pattern" per the turn-31 split.
pub const Cmp = enum(u6) {
    lt = 0,
    lte = 1,
    gt = 2,
    gte = 3,
    eq_num = 4,
    _,
};

/// Variants for the `math` group. Per PLAN §12.3 / VM.md §10.
/// Step #2 (COMPILER.md §10 #2) wires `add` only — the absolute
/// minimum needed to lower `(+ 1 2)` end-to-end. The remaining
/// variants are listed here so dispatch can distinguish
/// "known opcode, not yet wired" (UnimplementedOpcode) from
/// "unrecognized bit pattern" (BytecodeCorruption) per the
/// turn-31 split (peer-AI turn 33 confirmation).
pub const Math = enum(u6) {
    add = 0,
    sub = 1,
    mul = 2,
    div = 3,
    idiv = 4,
    mod = 5,
    pow = 6,
    neg = 7,
    abs = 8,
    _,
};

/// Packed 64-bit instruction. Field order matches PLAN §12.1:
/// [kind:4][group:6][variant:6][opA:16][opB:16][opC:16].
pub const Inst = packed struct(u64) {
    kind: InstKind,
    group: u6,
    variant: u6,
    a: Operand,
    b: Operand,
    c: Operand,

    pub fn primary(g: Group, v: anytype, a: Operand, b: Operand, c: Operand) Inst {
        return .{
            .kind = .primary,
            .group = @intFromEnum(g),
            .variant = @intCast(@intFromEnum(v)),
            .a = a,
            .b = b,
            .c = c,
        };
    }

    pub fn groupOf(self: Inst) Group {
        return @enumFromInt(self.group);
    }
};

comptime {
    std.debug.assert(@sizeOf(Inst) == 8);
    std.debug.assert(@sizeOf(Operand) == 2);
}

// =============================================================================
// Routine (VM.md §5)
//
// For this commit Routine is a plain Zig struct. Once the `fn*`
// lowering + closures land, routines will be wrapped in a heap
// Value of kind 22 (VALUE.md §2.2 `function`).
// =============================================================================

/// Typed entry in a routine's constant pool (peer-AI turn 40).
///
/// Routine prototypes are NOT user `Value`s; mixing them with
/// ordinary values would let `mov:load-const` load a prototype
/// into a slot and downstream ops produce malformed bytecode
/// that's harder to detect than a clean operand-kind error.
///
/// The typed pool enforces: `mov:load-const` requires
/// `Const.value`; `closure:make A=constant` requires
/// `Const.routine`. Mismatch raises `:invalid-operand-kind`.
pub const Const = union(enum) {
    value: Value,
    routine: *const Routine,
};

/// Source of one upvalue cell when constructing a closure.
/// (Per VM.md §6 capture descriptor sources, peer-AI turn 34.)
/// Step 5a1 introduces the type; only zero-source descriptors
/// are populated. Step 5b populates `local_cell_slot` /
/// `inherited_upvalue` entries during lazy-boxing capture.
pub const CaptureSource = union(enum) {
    /// Read raw `*UpvalCell` pointer from `caller.slot[index]`.
    /// The slot must hold a cell pointer (a previous
    /// `closure:box-local` or `closure:new-cell` populated it).
    local_cell_slot: u12,
    /// Copy raw cell pointer from `caller.upvalues[index]`. Used
    /// when an inner closure transitively captures something its
    /// enclosing closure already captured.
    inherited_upvalue: u12,
};

/// One descriptor used by a `closure:make` instruction. Each
/// `CaptureSource` corresponds to one upvalue slot in the
/// constructed closure. v1 step 5a1 only ever uses zero-source
/// descriptors (no captures).
pub const CaptureDescriptor = struct {
    sources: []const CaptureSource,
};

pub const Routine = struct {
    /// Bytecode instructions.
    code: []const Inst,
    /// Per-routine typed constant pool. Constant operands (`C#`)
    /// index into this array; the operand-using opcode determines
    /// which `Const` variant is required.
    consts: []const Const,
    /// Capture-descriptor table. Indexed by `closure:make`'s
    /// operand B per VM.md §5 amendment. v1 step 5a1: only the
    /// empty descriptor (zero sources) populated.
    capture_descs: []const CaptureDescriptor = &.{},
    /// Slot count. The frame reserves this many `Value` slots on
    /// invocation.
    slot_count: u16,
    /// Number of FIXED arguments this routine accepts. For a
    /// non-variadic routine, `call:call` must pass exactly
    /// `fixed_arity` args; mismatch raises `:arity-mismatch`
    /// (peer-AI turn 40). For a variadic routine
    /// (`variadic = true`), `call:call` must pass at least
    /// `fixed_arity` args and the rest are packed into a list
    /// installed at `slot[fixed_arity]` by the VM at call
    /// time (per VM.md §6 + peer-AI turn 49 Option D).
    /// (Renamed from `arity` in step 5e0.)
    fixed_arity: u16 = 0,
    /// If true, this routine takes a rest parameter at slot
    /// `fixed_arity`. The VM packs any excess args into a list
    /// at call time. `(fn* [a b & r] body)` lowers to
    /// `fixed_arity = 2, variadic = true`. Step 5e (peer-AI
    /// turn 49).
    variadic: bool = false,
    /// Number of upvalue cells the routine's body expects in
    /// its callee frame. Validated against the constructed
    /// closure's upvalue array length at `call:call` time and
    /// against `closure:make`'s descriptor source count at
    /// closure-construction time.
    upvalue_count: u16 = 0,
    /// Step #6a: per-routine Var table. The V operand index
    /// resolves through this table (analogous to const_pool
    /// for Values, capture_descs for closure construction).
    /// Caller (compileSymbol fall-through, step #6c) interns
    /// each referenced Var in the VM's Namespace and records
    /// the *Var here. Resolution is O(1) at runtime.
    var_table: []const *Var = &.{},
    /// Human-readable name for diagnostics. Non-owning.
    name: []const u8 = "<anonymous>",
};

/// A Var holds a mutable cell of a Value with stable identity
/// across rebinds (matches Clojure's `def` semantics: `(def x 5)`
/// then `(def x 10)` does NOT create a new Var; the same Var
/// object's root is updated). Per PLAN §6.1 + VM.md §6, step #6a.
///
/// Staged allocation (peer-AI turn 49): same pattern as
/// Closure/UpvalCell. Var lives in VM.runtime_arena; Value
/// payload is the raw `*Var`. When real GC integration lands,
/// this migrates to `heap.alloc(.var_, ...)` with a HeapHeader
/// prefix and the Value encoding becomes `*HeapHeader`.
///
/// `bound`: false until the first `(def name val)` runs. Loads
/// via `var:load-var` trap `:unbound-var` in that case. This
/// is what makes forward references work — `(defn f [] (g))`
/// compiles when g doesn't exist yet (g's Var is interned
/// unbound), and only traps if f is called before g is bound.
pub const Var = struct {
    /// Symbol name (the Var's identity). The Namespace that
    /// owns this Var owns the name's backing storage.
    name: []const u8,
    /// Current root value. Read by `var:load-var` / V-operand
    /// resolve. Written by `var:store-var` (step #6b).
    root: Value = value_mod.nilValue(),
    /// True once `def` has set the root. Distinguishes
    /// "intentionally nil" from "never bound".
    bound: bool = false,
    /// Phase 3.2 (peer-AI turn 66): true when this Var was
    /// created by `(defmacro ...)`. The expander dispatches
    /// macro Vars (compile-time evaluation of the macro fn)
    /// instead of compiling `(my-macro ...)` as an ordinary
    /// call. Set ONLY by the expander's defmacro handler;
    /// regular `def` never sets it.
    macro: bool = false,
    /// Reserved for metadata maps (doc, source location, etc.).
    /// Wired in Phase 3+.
    meta: Value = value_mod.nilValue(),
};

/// A namespace mapping symbol names to `*Var`. v1 has a single
/// global namespace per VM; multi-namespace machinery lands
/// later (peer-AI turn 49). Step #6a.
///
/// Lifetime: Var structs themselves live in VM.runtime_arena
/// and are freed wholesale at `VM.deinit`. The HashMap's
/// internal storage uses the same allocator the VM uses for
/// its other ArrayLists (VM.allocator); freed in
/// `Namespace.deinit`.
pub const Namespace = struct {
    /// Backs the HashMap's internal storage.
    map_allocator: std.mem.Allocator,
    /// Backs the Var struct allocations. Lifetime = VM lifetime.
    var_allocator: std.mem.Allocator,
    vars: std.StringHashMapUnmanaged(*Var) = .{},

    pub fn init(
        map_allocator: std.mem.Allocator,
        var_allocator: std.mem.Allocator,
    ) Namespace {
        return .{
            .map_allocator = map_allocator,
            .var_allocator = var_allocator,
        };
    }

    pub fn deinit(self: *Namespace) void {
        // Var structs are arena-owned; freed wholesale at
        // VM.deinit. Only the hash map's internal storage
        // belongs to us here.
        self.vars.deinit(self.map_allocator);
        self.* = undefined;
    }

    /// Look up an existing Var. Returns null if no Var was
    /// ever interned under `name`.
    pub fn lookup(self: *const Namespace, name: []const u8) ?*Var {
        return self.vars.get(name);
    }

    /// Get or create a Var for `name`. Newly-created Vars are
    /// unbound (root = nil, bound = false). The compiler uses
    /// this for forward references (step #6c).
    ///
    /// `name` lifetime: the caller must guarantee `name` outlives
    /// the Namespace, OR pass a stable copy. v1 tests pass
    /// string literals (program lifetime). Step #6c will dupe
    /// from Tiny.symbol via the compile arena.
    pub fn intern(self: *Namespace, name: []const u8) !*Var {
        if (self.vars.get(name)) |v| return v;
        const new_var = try self.var_allocator.create(Var);
        new_var.* = .{ .name = name };
        try self.vars.put(self.map_allocator, name, new_var);
        return new_var;
    }
};

/// Captured-binding cell. Heap object that holds one Value plus
/// an `initialized` flag (per VM.md §6 amendment, peer-AI
/// turn 34). v1 step 5a1: type defined but zero closures
/// actually capture anything; `closure:box-local` /
/// `closure:new-cell` / `closure:init-cell` lower in step 5b/5c.
pub const UpvalCell = struct {
    value: Value,
    initialized: bool,
};

/// Runtime closure object: a routine + its upvalue cells.
/// Per VALUE.md kind 22 = `function`.
///
/// **STAGED REPRESENTATION — TODO before GC integration**
/// (peer-AI turns 40 / 42 / 43): v1 step 5a1 allocates Closure
/// from VM-owned `runtime_arena` and stores a raw `*Closure`
/// pointer in `Value.payload`. **This is a deliberate temporary
/// violation** of the VALUE.md §4 heap-value contract, which
/// requires `Value.payload` for heap kinds to point at a
/// `HeapHeader`-prefixed object. The migration when real GC
/// integration lands (post-5c) requires:
///   1. Add a `header: HeapHeader` prefix field here.
///   2. Switch allocation to `heap.alloc(.function, ...)` so
///      the GC sees the object.
///   3. Wire `gc.zig`'s `.function` arm from panic-reserved to
///      a real trace function that walks `closure.upvalues`.
///   4. Update `allocClosure` and `asClosure` accordingly.
/// Field order (routine, upvalues) is migration-compatible
/// when the header prefix lands.
pub const Closure = struct {
    routine: *const Routine,
    /// Empty in 5a1 (zero captures); populated by `closure:make`
    /// in step 5b once capture descriptors carry sources.
    upvalues: []const *UpvalCell,
};

// =============================================================================
// Frame (VM.md §7)
//
// Step 5a0: backing-stack model (peer-AI turn 40). Each frame is a
// window into the VM's shared `stack` ArrayList, denoted by
// `base_slot..base_slot + slot_count`. This refactor preserves the
// single-frame runtime semantics — call:call / multi-frame dispatch
// land in step 5a1 — but evolves the storage so the range-call ABI
// (VM.md §6) can window the callee's slots over the caller's
// `[call_base + 1 .. call_base + 1 + argc]` region with zero copy.
//
// **Critical discipline** (peer-AI turn 40):
//   - Never store a `[]Value` slice into `vm.stack.items` and hold
//     it across any operation that might grow `stack` — ArrayList
//     can reallocate and invalidate the slice. Use the slotPtr()
//     helper for one-shot access; if you need stable references
//     mid-handler, snapshot the frame's `base_slot` into a local.
//   - Never hold a `*Frame` across `vm.frames.append()` for the
//     same reason. Step 5a1 will do `frames.append`, so all helpers
//     that take a frame pointer must be one-shot.
// =============================================================================

pub const Frame = struct {
    routine: *const Routine,
    /// Index into `vm.stack.items` where this frame's slot 0 lives.
    /// Frame's slot[i] is `vm.stack.items[base_slot + i]`.
    base_slot: u32,
    /// Logical slot count for bounds checks + (future) GC root walk.
    /// Always equals `routine.slot_count` at frame construction;
    /// kept on the frame for direct access in hot dispatch paths.
    slot_count: u16,
    /// Bytecode offset of the next instruction to execute.
    pc: u32 = 0,
    /// Where to write this frame's return value into the CALLER's
    /// slot space when `call:return` runs. Top-level frame ignores
    /// this; non-top-level frames receive it from `call:call`.
    return_dst: u12 = 0,
    /// PC to resume the caller at after `call:return`. Set by
    /// `call:call` to the caller's already-incremented PC (i.e.,
    /// the instruction following the call). Top-level frame
    /// ignores this. Per VM.md §6.
    return_pc: u32 = 0,
    /// Upvalue array sourced from the executing closure. Empty
    /// for the top-level frame and for empty-capture closures
    /// (5a1 only allocates these); populated by `closure:make` +
    /// `call:call` chain in step 5b.
    upvalues: []const *UpvalCell = &.{},
};

// =============================================================================
// Errors
// =============================================================================

pub const VmError = error{
    /// Known opcode / group / variant / operand kind that this VM
    /// commit hasn't wired yet (e.g., upvalue operand before
    /// closures land, cross-type math operands before promotion).
    /// Distinct from corruption — the encoding IS a recognized
    /// shape.
    UnimplementedOpcode,
    /// Operand index out of range for the operand's kind (e.g.,
    /// constant index >= routine.consts.len, slot index >=
    /// frame.slots.len).
    OperandOutOfRange,
    /// Operand's kind byte is not valid in this context — e.g.,
    /// `resolve` called on an `.unused` operand, or `store`
    /// called with a non-`.slot` destination. Distinct from
    /// OperandOutOfRange (which is about the index) and from
    /// BytecodeCorruption (which is about totally unrecognized
    /// encoding).
    InvalidOperandKind,
    /// `return` executed at the outermost frame (halt).
    Halt,
    /// Bytecode exhausted without an explicit `return`. Conservative
    /// error for the v1 skeleton; later commits add an implicit
    /// `return nil` at code-end.
    BytecodeExhausted,
    /// Unknown opcode group / variant / operand kind bit pattern
    /// (NOT in any recognized v1 enum space). Indicates
    /// bytecode corruption or bytecode from a newer nexis VM
    /// that this VM doesn't understand.
    BytecodeCorruption,
    /// `math:*` (or other kind-sensitive op) received an operand
    /// whose kind the current implementation doesn't support
    /// (e.g., float when fixnum-only is wired). Mirrors the
    /// `:kind-mismatch` user-visible error kind from VM.md §13;
    /// reusing the existing taxonomy avoids a parallel
    /// "type-error" category drifting in (peer-AI turn 33).
    /// Step #2 wires fixnum+fixnum for math:add; floats /
    /// bignums / cross-type all surface this. Subsequent commits
    /// widen the supported set; the ultimate behavior (per PLAN
    /// §6.3) is fixnum→bignum promotion on overflow and an
    /// arithmetic exception on non-numeric operands.
    KindMismatch,
    /// fixnum + fixnum overflowed i48. The eventual behavior is
    /// promotion to bignum (PLAN §6.3 + §8.3); until bignum
    /// arithmetic Scope B lands, this surfaces as a hard error
    /// so we don't silently lose precision.
    IntegerOverflow,
    /// `call:call` / `call:tailcall` invocation passed a different
    /// number of arguments than the callee closure's routine
    /// declares. Per VM.md §13 `:arity-mismatch` row (peer-AI
    /// turn 40 clarification): runtime arity check fired at
    /// frame transfer, distinct from compile-time arity errors
    /// in COMPILER.md §4.3.
    ArityMismatch,
    /// `call:call` target slot did not contain a closure value.
    /// Per VM.md §13 `:not-callable` row.
    NotCallable,
    /// `call:call` references a `call_base` slot such that
    /// `slot[A + argc]` exceeds the frame's slot count. Per
    /// VM.md §13 `:call-block-out-of-range`. Indicates a
    /// compiler bug — call block was not allocated within the
    /// routine's `slot_count`.
    CallBlockOutOfRange,
    /// `closure:make` capture descriptor's source count does not
    /// match the child routine's `upvalue_count`. Indicates a
    /// compiler bug.
    CaptureCountMismatch,
    /// Allocator failure during runtime allocation (Closure,
    /// UpvalCell, stack growth, frame push). v1 surfaces this as
    /// a generic OutOfMemory; a future commit may grow the
    /// VM.md §13 taxonomy with a richer `:out-of-memory`
    /// runtime error category that carries context.
    OutOfMemory,
    /// `U` operand index exceeds the current frame's
    /// `upvalues.len`, OR a `closure:make` `inherited_upvalue`
    /// descriptor source exceeds it. Per VM.md §13
    /// `:upvalue-out-of-range` (peer-AI turn 34).
    UpvalueOutOfRange,
    /// An opcode that requires an `UpvalCell*` in a slot (e.g.,
    /// `closure:get-cell`, `closure:make` `local_cell_slot`
    /// source) found a different Value kind in the slot. Per
    /// VM.md §13 `:expected-cell` (peer-AI turn 34).
    ExpectedCell,
    /// `closure:box-local` invoked on a slot that already holds
    /// an `UpvalCell*` (double-box), OR `closure:init-cell` on
    /// an already-initialized cell. Per VM.md §13
    /// `:invalid-cell-state` (peer-AI turn 34). Indicates a
    /// compiler bug — should never reach the runtime.
    InvalidCellState,
    /// `closure:get-cell` (or U-operand resolve) read a cell
    /// whose `initialized = false` — a placeholder cell that
    /// has not yet been filled in. Per VM.md §13
    /// `:uninitialized-cell` (peer-AI turn 34). Indicates a
    /// `closure:init-cell` was emitted out of order or skipped
    /// entirely.
    UninitializedCell,

    /// Step #9.1 (peer-AI turn 59): a `ctrl:throw` walked the
    /// entire frame chain without finding a matching handler.
    /// Halts the VM; the thrown value is preserved in
    /// `VM.unhandled_throw` for diagnostics (#10 will surface
    /// this with source span context).
    UncaughtThrow,
    /// Step #9.1: handler stack is in an invalid state —
    /// `ctrl:try-exit` referenced a handler that doesn't
    /// belong to the current frame, or popping found nothing.
    /// Indicates compiler bug, not user error.
    InvalidHandlerState,
    /// V-operand resolve (or `var:load-var`) read a Var whose
    /// `bound = false` — the Var was interned (e.g., by a
    /// forward reference in another `defn`) but no `def` has
    /// set its root yet. Per VM.md §13 `:unbound-var`
    /// (peer-AI turn 49). Recoverable error (user can `def`
    /// the var and retry).
    UnboundVar,
};

// =============================================================================
// Try / catch / throw machinery (step #9.1, peer-AI turn 59)
// =============================================================================

/// What kind of frame-bound exception handler this is.
pub const HandlerKind = enum {
    /// A `(try body (catch any x handler))` is active —
    /// catch_pc + binding_slot are valid; throw routes here.
    try_,
    /// The catch body of a fired try is running — preserves
    /// per-handler bookkeeping (e.g., per-#9.2 finally_pc)
    /// for the catch body's `try-exit`. Prevents the catch
    /// body's own throw from being re-caught by the same
    /// handler (peer-AI turn 59 §"Missing trap 1" — the
    /// classic catch-body-rethrow trap).
    cleanup,
};

/// Per-handler state stored on `VM.handlers`. Per peer-AI
/// turn 59 §D2: a VM-global stack keyed by `frame_index`
/// (instead of per-frame ArrayLists). Cheaper to manage, no
/// per-frame init/deinit, frame indices stable under
/// `frames.append` reallocations because frames only pop
/// from the top.
pub const Handler = struct {
    kind: HandlerKind,
    /// Index into `VM.frames`. Identifies which frame this
    /// handler belongs to; on `ctrl:try-exit` the popped
    /// handler's frame_index MUST match the current frame.
    frame_index: usize,
    /// PC of the catch entry (valid only when kind == .try_).
    /// Throw routes control here, after binding the thrown
    /// value into `binding_slot`.
    catch_pc: u32,
    /// Slot into which the thrown value is stored when the
    /// catch fires. Valid only when kind == .try_.
    binding_slot: u12,
    /// Step #9.2: PC of the finally entry. null when the try
    /// has no finally clause. Both .try_ and .cleanup handlers
    /// carry this so unwind through either kind runs the
    /// finally.
    finally_pc: ?u32 = null,
    /// Stack depth (logical, NOT physical) when the handler
    /// was registered. On throw-unwind, shrink stack back to
    /// this. v1: equal to frame.slot_count for the registering
    /// frame (we don't yet have dynamic stack growth within a
    /// frame), but reserved for future call-window cleanup.
    saved_stack_len: usize,
};

/// Step #9.2 (peer-AI turn 59 §D5): tagged continuation for
/// finally bodies. When a try-exit / catch-exit / throw-unwind
/// path needs to run a finally, it pushes a continuation onto
/// `VM.finally_stack` describing what to do AFTER the finally
/// finishes.
pub const FinallyReason = union(enum) {
    /// Finally was reached via normal/caught exit. Resume at
    /// `post_pc` after the finally body completes.
    normal: u32,
    /// Finally was reached during throw-unwind. The thrown
    /// value must continue propagating after the finally
    /// completes.
    throwing: Value,
};

pub const FinallyContinuation = struct {
    /// Frame the originating handler belonged to. Used as a
    /// sanity check at finally-exit time.
    frame_index: usize,
    reason: FinallyReason,
};

// =============================================================================
// VM
// =============================================================================

pub const VM = struct {
    allocator: std.mem.Allocator,
    /// Backing slot storage shared across all frames. Per-frame
    /// access uses `frame.base_slot + slot_index` indirection.
    stack: std.ArrayList(Value) = .empty,
    /// Frame chain. Step 5a0: always exactly one frame (the
    /// top-level routine). Step 5a1: `call:call` appends; `call:return`
    /// pops.
    frames: std.ArrayList(Frame) = .empty,
    /// Runtime allocation arena for `Closure` and `UpvalCell`
    /// objects (peer-AI turn 40 + 42: VM-owned allocation, defer
    /// real GC). Lifetime = VM lifetime; freed wholesale in
    /// `deinit`. When real GC integration lands (post-5c),
    /// allocations migrate to gc-managed `heap.alloc` calls; the
    /// Closure/UpvalCell layouts stay trace-compatible.
    runtime_arena: std.heap.ArenaAllocator,
    /// Step 5e: heap for runtime list construction (variadic
    /// rest args). Backed by `runtime_arena.allocator()` so list
    /// nodes share the closure/cell lifetime — all freed at
    /// `VM.deinit`. Initialized lazily on first variadic call
    /// to avoid the cost on programs that never use variadic
    /// fns.
    heap: ?heap_mod.Heap = null,
    /// Step #6a: global namespace for Vars. Lazy-initialized
    /// on first access (no cost for programs that don't use
    /// Vars). Var structs allocate from `runtime_arena`; the
    /// HashMap's internal storage uses `allocator`.
    /// v1 has a single global namespace; multi-namespace
    /// machinery lands later.
    namespace: ?Namespace = null,
    /// Step #9.1: global try-handler stack (peer-AI turn 59
    /// §D2). Push on `ctrl:try-enter`, pop on `ctrl:try-exit`,
    /// walk on `ctrl:throw`. Each Handler is keyed by
    /// `frame_index` so throw-unwind can identify which frame
    /// it belongs to.
    handlers: std.ArrayList(Handler) = .empty,
    /// Step #9.2: finally continuation stack. Pushed by
    /// try-exit (when the popped handler has a finally) and by
    /// throw-unwind (when a finally must run before the throw
    /// continues). Popped by finally-exit.
    finally_stack: std.ArrayList(FinallyContinuation) = .empty,
    /// Step #9.1: if a `ctrl:throw` walks the entire frame
    /// chain without finding a matching handler, the VM halts
    /// with `VmError.UncaughtThrow` AND stores the thrown
    /// payload here. Step #10 will surface this with source
    /// span context.
    unhandled_throw: ?Value = null,
    /// Step E1 (pre-#8): shared Interner for symbol/keyword
    /// Value construction. Lazy-initialized on first access.
    /// Used by the compiler's `lowerQuotePayload` for quoted
    /// symbols/keywords and (post-#8) by the macroexpander for
    /// auto-gensym and syntax-quote output. Backed by
    /// `self.allocator` (NOT runtime_arena) because the
    /// Interner's internal hash maps need a real allocator
    /// that supports realloc/free, which arena doesn't.
    interner: ?intern_mod.Interner = null,
    /// Where the top-level `call:return` stores the returned Value on
    /// halt.
    result: Value = value_mod.nilValue(),
    halted: bool = false,
    /// High-water marks for the backing stack and frame stack
    /// (peer-AI turn 47). Used by `recur`/`loop*` tests to assert
    /// that long-running iteration runs in bounded stack space
    /// (PLAN §11.3 constant-stack guarantee). Updated on grow
    /// operations only — comparing pre/post run-loop values gives
    /// a true maximum, not just the final size (a buggy
    /// implementation could grow and shrink, leaving final size
    /// equal but high-water inflated).
    stack_high_water: usize = 0,
    frame_high_water: usize = 0,

    /// Build a VM around `routine`, allocating a single top-level
    /// frame with `routine.slot_count` slots zero-initialized to nil.
    /// Caller owns the lifetime of `routine`; VM owns the stack,
    /// frames, and runtime arena and frees them in `deinit`.
    pub fn init(allocator: std.mem.Allocator, routine: *const Routine) !VM {
        var stack: std.ArrayList(Value) = .empty;
        errdefer stack.deinit(allocator);
        try stack.appendNTimes(allocator, value_mod.nilValue(), routine.slot_count);

        var frames: std.ArrayList(Frame) = .empty;
        errdefer frames.deinit(allocator);
        try frames.append(allocator, .{
            .routine = routine,
            .base_slot = 0,
            .slot_count = routine.slot_count,
            .pc = 0,
        });

        return .{
            .allocator = allocator,
            .stack = stack,
            .frames = frames,
            .runtime_arena = std.heap.ArenaAllocator.init(allocator),
            .stack_high_water = stack.items.len,
            .frame_high_water = frames.items.len,
        };
    }

    pub fn deinit(self: *VM) void {
        // Step #9.1/#9.2: free handler + finally stack backing
        // storage. Both contain POD entries.
        self.handlers.deinit(self.allocator);
        self.finally_stack.deinit(self.allocator);
        // Interner owns hash maps allocated via self.allocator;
        // free explicitly (step E1).
        if (self.interner) |*it| it.deinit();
        // Namespace's HashMap storage belongs to us (allocated
        // via self.allocator). Free it explicitly. Var struct
        // memory itself is arena-backed and gets freed below.
        if (self.namespace) |*ns| ns.deinit();
        // Heap (if initialized) is arena-backed in this staged
        // VM path. Its live-list is only bookkeeping; all
        // memory is reclaimed by `runtime_arena.deinit()`
        // below. We deliberately skip `heap.deinit()` because
        // (1) the Heap holds no non-memory resources, (2)
        // every allocation it owns came from runtime_arena,
        // and (3) the surrounding `self.* = undefined` makes
        // the field unreachable after this returns.
        // Migration warning: if a future change backs `VM.heap`
        // by `self.allocator` (instead of runtime_arena), this
        // skip becomes a leak — call `heap.deinit()` then.
        self.runtime_arena.deinit();
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }

    /// Step #6a: lazy-initialize the global Namespace on first
    /// use. HashMap storage uses `self.allocator` (heap-grown);
    /// Var structs use `runtime_arena` (lifetime = VM lifetime).
    pub fn ensureNamespace(self: *VM) *Namespace {
        if (self.namespace == null) {
            self.namespace = Namespace.init(self.allocator, self.runtime_arena.allocator());
        }
        return &self.namespace.?;
    }

    /// Step E1: lazy-initialize the shared Interner on first
    /// use. The Interner owns hash maps that need realloc/free,
    /// so it's backed by `self.allocator`, NOT runtime_arena.
    /// Symbol/keyword names are owned by the Interner (it
    /// dupes on intern). Interner.deinit in `VM.deinit` frees
    /// every interned name.
    pub fn ensureInterner(self: *VM) *intern_mod.Interner {
        if (self.interner == null) {
            self.interner = intern_mod.Interner.init(self.allocator);
        }
        return &self.interner.?;
    }

    /// Step 5e: lazy-initialize the rest-list heap on first use
    /// (peer-AI turn 49). The Heap is just an allocator wrapper
    /// with a live-list; init is O(1) and there's no cost
    /// before the first variadic call.
    fn ensureHeap(self: *VM) *heap_mod.Heap {
        if (self.heap == null) {
            self.heap = heap_mod.Heap.init(self.runtime_arena.allocator());
        }
        return &self.heap.?;
    }

    /// Allocate a `Closure` from the runtime arena and return a
    /// `Value` of kind `.function` pointing at it. The Value
    /// payload encoding (raw `*Closure` pointer in payload) is
    /// 5a1's staged-realization shape per peer-AI turn 42 — when
    /// real GC integration lands, the closure migrates to a
    /// `heap.alloc(.function, ...)` call with HeapHeader prefix
    /// and the Value encoding becomes `*HeapHeader` per VALUE.md
    /// §4. `asClosure()` is the matched accessor; both must
    /// migrate together at that future cutover.
    pub fn allocClosure(
        self: *VM,
        routine: *const Routine,
        upvalues: []const *UpvalCell,
    ) !Value {
        const arena = self.runtime_arena.allocator();
        const c = try arena.create(Closure);
        c.* = .{ .routine = routine, .upvalues = upvalues };
        return Value{
            .tag = @as(u64, @intFromEnum(value_mod.Kind.function)),
            .payload = @intFromPtr(c),
        };
    }

    /// Inverse of `allocClosure`. Asserts `v.kind() == .function`
    /// in safety builds; in release the cast is direct. Migration
    /// note: when closures move to heap.alloc, this will need to
    /// translate the `*HeapHeader` payload to `*Closure` body.
    pub fn asClosure(v: Value) *const Closure {
        std.debug.assert(v.kind() == .function);
        return @ptrFromInt(v.payload);
    }

    /// Phase 3.2 (peer-AI turn 66): invoke `closure` with `args`
    /// in a FRESH sub-VM, returning the result Value. Used by
    /// the expander for compile-time macro evaluation.
    ///
    /// **Why fresh-VM-per-call**: avoids save/restore of the
    /// caller's VM state (handlers, finally stack, halted flag,
    /// frame stack). Each invocation gets isolated heap +
    /// frame state. The closure's routine carries its `var_table`
    /// (pointers into the caller's namespace) and constant pool
    /// (literals interned by the caller's interner) directly,
    /// so the sub-VM doesn't need a namespace/interner of its
    /// own for the macro body to read or mutate the caller's
    /// Vars. Symbols/keywords emitted by the macro come from
    /// the caller's interner via the routine's literal pool.
    ///
    /// **Lifetime**: the returned Value may reference the
    /// sub-VM's `runtime_arena` (list nodes, closures, maps,
    /// vectors). The caller MUST convert the result to a
    /// caller-arena-owned form (typically by walking it into a
    /// Form tree on the compile arena) BEFORE calling `deinit`
    /// on the sub-VM. `out_vm` is written so the caller controls
    /// the deinit timing.
    pub fn evalClosure(
        allocator: std.mem.Allocator,
        closure_v: Value,
        args: []const Value,
        out_vm: *VM,
    ) !Value {
        if (closure_v.kind() != .function) return error.NotCallable;
        const closure = VM.asClosure(closure_v);
        const routine = closure.routine;

        // Arity check.
        if (routine.variadic) {
            if (args.len < routine.fixed_arity) return error.ArityMismatch;
        } else {
            if (args.len != routine.fixed_arity) return error.ArityMismatch;
        }

        out_vm.* = try VM.init(allocator, routine);

        // Wire the frame's upvalues to the closure's captures.
        out_vm.frames.items[0].upvalues = closure.upvalues;

        // Populate the fixed-arity args into slots.
        const fixed: usize = routine.fixed_arity;
        var i: usize = 0;
        while (i < fixed) : (i += 1) {
            out_vm.stack.items[i] = args[i];
        }

        // For variadic, build the rest list from the excess args.
        if (routine.variadic) {
            const heap = out_vm.ensureHeap();
            var rest = list_mod.empty(heap) catch return error.OutOfMemory;
            var j: usize = args.len;
            while (j > fixed) {
                j -= 1;
                rest = list_mod.cons(heap, args[j], rest) catch return error.OutOfMemory;
            }
            if (fixed < out_vm.stack.items.len) {
                out_vm.stack.items[fixed] = rest;
            }
        }

        return try out_vm.run();
    }

    /// Step #6b: pack a `*Var` into a `Value` of kind `.var_`.
    /// Used by `var:store-var` (returns the Var object so
    /// `(def x 5)` evaluates to the Var, not the value 5) and
    /// by `var:var-object` (Clojure's `(var x)` reader form).
    /// Staged encoding (raw *Var in payload, NOT *HeapHeader)
    /// matches Closure/UpvalCell; migrates with the GC cutover.
    pub fn varToValue(v: *Var) Value {
        return Value{
            .tag = @as(u64, @intFromEnum(value_mod.Kind.var_)),
            .payload = @intFromPtr(v),
        };
    }

    pub fn asVar(v: Value) *Var {
        std.debug.assert(v.kind() == .var_);
        return @ptrFromInt(v.payload);
    }

    /// Allocate an UpvalCell from the runtime arena, return a
    /// VM-private `Value` of kind `.cell_internal` whose payload
    /// points at the cell. Step 5b box-local emission: when the
    /// compiler discovers a binding is captured, it emits
    /// `closure:box-local s` which calls `boxCell(slot[s].value)`
    /// and replaces slot[s] with the returned cell-value. Same
    /// staged-allocation discipline as `allocClosure` — VM-owned
    /// arena lifetime, migration-compatible with future GC heap.
    pub fn allocCell(self: *VM, initial: Value, initialized: bool) !Value {
        const arena = self.runtime_arena.allocator();
        const cell = try arena.create(UpvalCell);
        cell.* = .{ .value = initial, .initialized = initialized };
        return Value{
            .tag = @as(u64, @intFromEnum(value_mod.Kind.cell_internal)),
            .payload = @intFromPtr(cell),
        };
    }

    /// Decode a `.cell_internal` Value to its underlying
    /// `*UpvalCell`. Returns `ExpectedCell` if the Value's kind
    /// is anything else (peer-AI turn 34: `:expected-cell` runtime
    /// trap). Callers that already validated the kind (e.g., via
    /// a `BindingRef.cell_slot` lookup) can use
    /// `asCellUnchecked`; user-facing handlers should use this
    /// validating variant.
    pub fn asCell(v: Value) VmError!*UpvalCell {
        if (v.kind() != value_mod.Kind.cell_internal) return VmError.ExpectedCell;
        return @ptrFromInt(v.payload);
    }

    /// Unchecked variant of `asCell` for paths that have already
    /// validated the Value's kind. Safety builds still assert.
    pub fn asCellUnchecked(v: Value) *UpvalCell {
        std.debug.assert(v.kind() == value_mod.Kind.cell_internal);
        return @ptrFromInt(v.payload);
    }

    /// Pointer to the currently-executing frame. **Single-shot use
    /// only**: a `frames.append()` in any code path between fetch
    /// and use will invalidate this pointer. For multi-step access,
    /// read the relevant fields into locals or use `currentFrameIdx`.
    inline fn currentFrame(self: *VM) *Frame {
        // Empty frame stack is a VM invariant violation, not a
        // recoverable runtime condition (peer-AI turn 41).
        std.debug.assert(self.frames.items.len > 0);
        return &self.frames.items[self.frames.items.len - 1];
    }

    /// Index of the currently-executing frame. Stable across
    /// `frames.append()` for the existing frames (a new frame
    /// pushes at len; the prior current frame keeps its index).
    inline fn currentFrameIdx(self: *const VM) usize {
        return self.frames.items.len - 1;
    }

    /// Resolve a slot operand to a pointer into the backing stack.
    /// Returns `OperandOutOfRange` if the slot index exceeds the
    /// current frame's `slot_count`. **Single-shot use only**: the
    /// returned pointer is invalidated by any `stack.append` /
    /// `stack.appendNTimes`.
    ///
    /// Peer-AI turn 41: two bounds checks, not one.
    /// - Logical (`slot_count`): catches bad bytecode. Step 5a1's
    ///   call:call will produce overlapping frame windows where
    ///   `stack.items.len > base_slot + slot_count` for the caller
    ///   even after the callee has been popped, so the logical
    ///   check is what defines a frame's visible slot range.
    /// - Physical (`stack.items.len`): catches corrupt VM/frame
    ///   state. In 5a0 this is always satisfied if the logical
    ///   check passes, but in 5a1 a stale `slot_count` paired
    ///   with a shrunken stack could underrun otherwise.
    fn slotPtr(self: *VM, slot_index: u12) VmError!*Value {
        const frame = self.currentFrame();
        if (slot_index >= frame.slot_count) return VmError.OperandOutOfRange;
        const absolute: usize = @as(usize, frame.base_slot) + slot_index;
        if (absolute >= self.stack.items.len) return VmError.BytecodeCorruption;
        return &self.stack.items[absolute];
    }

    /// Resolve an operand to a `Value` (read side).
    ///
    /// For `.constant` operands the typed `Const` pool requires
    /// the entry to be `Const.value`. A `Const.routine` entry
    /// raises `InvalidOperandKind` (peer-AI turn 40 typed-pool
    /// enforcement) — `closure:make` is the only opcode that
    /// reads routine constants, and it does so via a dedicated
    /// path, not through generic `resolve()`.
    ///
    /// For `.upvalue` operands (step 5b, peer-AI turns 34/40):
    /// `U` is the **cell-contents** operand kind. `resolve(u:N)`
    /// reads the current frame's `upvalues[N]` (a `*UpvalCell`),
    /// validates it's `initialized = true`, and returns the
    /// cell's value. Closure construction needs RAW cell pointers
    /// (not contents) and does NOT go through `resolve()` — it
    /// reads `frame.upvalues[u]` directly via a dedicated path
    /// in `execClosureMake`. Do not conflate the two.
    fn resolve(self: *VM, op: Operand) VmError!Value {
        return switch (op.kind) {
            .slot => (try self.slotPtr(op.index)).*,
            .constant => blk: {
                const consts = self.currentFrame().routine.consts;
                if (op.index >= consts.len) return VmError.OperandOutOfRange;
                break :blk switch (consts[op.index]) {
                    .value => |v| v,
                    .routine => return VmError.InvalidOperandKind,
                };
            },
            .upvalue => blk: {
                const frame = self.currentFrame();
                if (op.index >= frame.upvalues.len) return VmError.UpvalueOutOfRange;
                const cell = frame.upvalues[op.index];
                if (!cell.initialized) return VmError.UninitializedCell;
                break :blk cell.value;
            },
            // Step #6a: V operand kind resolves through the
            // current routine's var_table to the Var's root
            // value. Unbound Vars (`!bound`) trap
            // `:unbound-var` — this is what makes forward
            // references work: compile time creates the Var,
            // runtime traps only if the Var is read before
            // any `def` has bound it.
            .var_ => blk: {
                const var_table = self.currentFrame().routine.var_table;
                if (op.index >= var_table.len) return VmError.OperandOutOfRange;
                const v = var_table[op.index];
                if (!v.bound) return VmError.UnboundVar;
                break :blk v.root;
            },
            // Remaining kinds land with their respective opcode groups.
            .intern, .jump, .durable => VmError.UnimplementedOpcode,
            // `unused` is a sentinel emitted by the assembler for
            // operand slots the opcode doesn't consume; calling
            // `resolve` on one is an opcode-handler bug.
            .unused => VmError.InvalidOperandKind,
            // Unrecognized kind bit pattern — bytecode corruption.
            _ => VmError.BytecodeCorruption,
        };
    }

    /// Write a `Value` into a destination operand.
    ///
    /// Only `.slot` is a valid destination for the generic store
    /// path. Other kinds split into two categories per VM.md §13
    /// (peer-AI turn 35 alignment with the published taxonomy):
    ///
    ///   - `.upvalue`: future-valid destination (Phase 3+ dynamic-
    ///     binding rebinding will write through cells via the U
    ///     store path). Returns `UnimplementedOpcode` for now.
    ///   - `.constant`, `.intern`, `.jump`, `.durable`: read-only
    ///     operand kinds; writing to them is invalid in this
    ///     opcode context, NOT "not yet wired." Surface
    ///     `InvalidOperandKind` per VM.md §13's `:invalid-operand-
    ///     kind` row.
    ///   - `.var_`: var writes go through `var:store-var` (a
    ///     dedicated opcode), not the generic store path. Generic
    ///     store with a `.var_` destination is a handler bug.
    ///     Surface `InvalidOperandKind`.
    ///   - `.unused`: invalid in any context with a destination
    ///     operand.
    fn store(self: *VM, op: Operand, v: Value) VmError!void {
        switch (op.kind) {
            .slot => (try self.slotPtr(op.index)).* = v,
            .upvalue => return VmError.UnimplementedOpcode,
            .constant, .var_, .intern, .jump, .durable, .unused => return VmError.InvalidOperandKind,
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// Run bytecode to completion (halt). Returns the VM's `result`
    /// slot. If bytecode exhausts without a `return`, returns
    /// `BytecodeExhausted`.
    ///
    /// Peer-AI turn 41: the `frame` pointer is scoped inside a
    /// nested block so it cannot accidentally be reused after
    /// `dispatch()` — `dispatch` may grow `frames` in step 5a1
    /// (call:call) and invalidate the pointer. The block-scoping
    /// makes the lifetime structurally obvious rather than just
    /// conventionally true.
    pub fn run(self: *VM) VmError!Value {
        while (!self.halted) {
            const inst = blk: {
                const frame = self.currentFrame();
                if (frame.pc >= frame.routine.code.len) {
                    return VmError.BytecodeExhausted;
                }
                const i = frame.routine.code[frame.pc];
                frame.pc += 1;
                // Extension instructions are reserved; skip for now.
                if (i.kind == .extension) return VmError.UnimplementedOpcode;
                break :blk i;
            };

            self.dispatch(inst) catch |err| {
                // Phase 3.0c (peer-AI turn 62 §"Implementation
                // model"): recoverable VM errors get translated
                // into user Values and routed through the same
                // unwind machinery as `ctrl:throw`. If no handler
                // catches, the throw bubbles back out as
                // UncaughtThrow (with the keyword payload in
                // `unhandled_throw`).
                try self.handleRuntimeError(err);
            };
        }
        return self.result;
    }

    /// Run bytecode with a step budget. Returns `BytecodeExhausted`
    /// if the routine completes within the budget without halting;
    /// returns the result Value on normal halt. Intended for tests
    /// that exercise potentially-pathological bytecode (peer-AI
    /// turn 37) — using `run()` for malformed/unimplemented opcode
    /// tests risks 22-minute hangs when the bytecode happens to
    /// decode as a self-targeting jump. Same frame-pointer scoping
    /// discipline as `run()` (peer-AI turn 41).
    pub fn runWithFuel(self: *VM, max_steps: usize) VmError!Value {
        var steps: usize = 0;
        while (!self.halted) : (steps += 1) {
            if (steps >= max_steps) return VmError.BytecodeExhausted;
            const inst = blk: {
                const frame = self.currentFrame();
                if (frame.pc >= frame.routine.code.len) {
                    return VmError.BytecodeExhausted;
                }
                const i = frame.routine.code[frame.pc];
                frame.pc += 1;
                if (i.kind == .extension) return VmError.UnimplementedOpcode;
                break :blk i;
            };
            self.dispatch(inst) catch |err| try self.handleRuntimeError(err);
        }
        return self.result;
    }

    /// Phase 3.0c (peer-AI turn 62): runtime error translation
    /// to a user-throwable Value. Recoverable errors (per VM.md
    /// §13 "Recoverable via try/catch" column) become keyword
    /// payloads routed through `unwindThrow`; non-recoverable
    /// errors (bytecode corruption, OOM, etc.) bubble back out
    /// unchanged.
    ///
    /// Translation: each recoverable VmError maps to a keyword
    /// like `:kind-mismatch`. Per turn 62: keyword for v1
    /// (simpler than maps; we don't have rich map literals at
    /// the throw site yet).
    ///
    /// Note: throw machinery via unwindThrow may itself raise
    /// UncaughtThrow (if no handler catches the translated
    /// payload). That propagates back to the dispatch caller
    /// just like a user-level `(throw)`.
    fn handleRuntimeError(self: *VM, err: VmError) VmError!void {
        const kw_name = vmErrorToKeywordName(err) orelse return err;
        // Only translate to a throwable Value if there's an
        // active handler that could catch it. Otherwise let
        // the raw VmError propagate — preserves backward
        // compat with existing tests that assert specific
        // VmError variants AND matches the principle of
        // least surprise: programs that don't opt into
        // try/catch see the original error taxonomy.
        if (self.findThrowTarget() == null) return err;
        const interner = self.ensureInterner();
        const id = interner.internKeyword(kw_name) catch return err;
        const payload = value_mod.fromKeywordId(id);
        try self.unwindThrow(payload);
    }

    /// Two-level switch dispatcher. Tail-call-threaded upgrade is
    /// deferred (VM.md §8 contract is "tail-call-threaded"; this
    /// implementation is semantically equivalent via the simpler
    /// switch — latitude per PLAN §12.5 fallback).
    fn dispatch(self: *VM, inst: Inst) VmError!void {
        const g = inst.groupOf();
        switch (g) {
            .mov => try self.execMov(inst),
            .call => try self.execCall(inst),
            .math => try self.execMath(inst),
            .cmp => try self.execCmp(inst),
            .jump => try self.execJump(inst),
            .closure => try self.execClosure(inst),
            .var_ => try self.execVar(inst),
            .coll => try self.execColl(inst),
            .ctrl => try self.execCtrl(inst),
            // Known but not yet implemented in this commit.
            .transient, .hash, .tx, .io, .simd => return VmError.UnimplementedOpcode,
            // Unrecognized group byte — bytecode corruption.
            _ => return VmError.BytecodeCorruption,
        }
    }

    // -------------------------------------------------------------------------
    // Group `mov` (VM.md §10 #3)
    // -------------------------------------------------------------------------

    fn execMov(self: *VM, inst: Inst) VmError!void {
        const variant: Mov = @enumFromInt(inst.variant);
        switch (variant) {
            .move => {
                // mov:move a b _      ;  slot[a] = resolve(b)
                const v = try self.resolve(inst.b);
                try self.store(inst.a, v);
            },
            .load_const => {
                // mov:load-const a c _  ;  slot[a] = consts[c]
                const v = try self.resolve(inst.b);
                try self.store(inst.a, v);
            },
            .load_nil => {
                try self.store(inst.a, value_mod.nilValue());
            },
            .load_true => {
                try self.store(inst.a, value_mod.fromBool(true));
            },
            .load_false => {
                try self.store(inst.a, value_mod.fromBool(false));
            },
            _ => return VmError.UnimplementedOpcode,
        }
    }

    // -------------------------------------------------------------------------
    // Group `call` (VM.md §10 #4)
    // -------------------------------------------------------------------------

    fn execCall(self: *VM, inst: Inst) VmError!void {
        const variant: Call = @enumFromInt(inst.variant);
        switch (variant) {
            .call => try self.execCallCall(inst),
            .@"return" => try self.execCallReturn(inst),
            .return_nil => try self.execCallReturnNil(),
            // tailcall lands in step #6 (recur + loop*).
            .tailcall => return VmError.UnimplementedOpcode,
            _ => return VmError.UnimplementedOpcode,
        }
    }

    /// `call:call A=call_base B=argc C=result_slot` — range-call
    /// ABI per VM.md §6 (peer-AI turn 32). Caller has staged
    /// `slot[A] = closure` and `slot[A+1 .. A+1+argc] = args`.
    /// On return, the call's result lands in `slot[C]` and the
    /// caller resumes at the instruction following this one.
    fn execCallCall(self: *VM, inst: Inst) VmError!void {
        // Operand kind validation per VM.md §13. A and C are
        // slot operands; B is a raw-index immediate (kind ignored
        // per §4.5 raw-index convention).
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.c.kind != .slot) return VmError.InvalidOperandKind;

        const call_base: u32 = inst.a.index;
        const argc: u32 = inst.b.index;
        const result_dst: u12 = inst.c.index;

        // Validate the call block fits within the caller's frame
        // (peer-AI turn 42: avoid u12 overflow with u32 math).
        // The closure occupies slot[A], args are at A+1..A+argc.
        // Compiler invariant: caller's slot_count >= A + 1 + argc.
        const caller_idx = self.currentFrameIdx();
        {
            const caller_frame = self.currentFrame();
            const required: u32 = call_base + 1 + argc;
            if (required > caller_frame.slot_count) {
                return VmError.CallBlockOutOfRange;
            }
        }

        // Read closure value from slot[call_base]. Copy the Value
        // by value (16 bytes) so we don't hold a *Value across
        // stack growth (peer-AI turn 41 + 42).
        const closure_v = (try self.slotPtr(@intCast(call_base))).*;
        if (closure_v.kind() != value_mod.Kind.function) {
            return VmError.NotCallable;
        }
        const closure = asClosure(closure_v);
        const callee_routine = closure.routine;

        // Arity check (peer-AI turn 42 + step 5e0):
        //   non-variadic: argc must equal fixed_arity
        //   variadic:     argc must be >= fixed_arity (excess
        //                 args get packed into a rest list by
        //                 the VM at call/prologue time below)
        if (callee_routine.variadic) {
            if (argc < callee_routine.fixed_arity) {
                return VmError.ArityMismatch;
            }
        } else {
            if (callee_routine.fixed_arity != argc) {
                return VmError.ArityMismatch;
            }
        }
        // Upvalue count consistency check: the closure's upvalue
        // array length must match what the routine expects.
        // Indicates `closure:make` was emitted with a wrong-size
        // descriptor, OR the closure was constructed by a
        // different routine. Trap as CaptureCountMismatch
        // (peer-AI turn 42).
        if (closure.upvalues.len != callee_routine.upvalue_count) {
            return VmError.CaptureCountMismatch;
        }
        // Validate result slot fits within caller's frame
        // (peer-AI turn 43): rejecting at call time is cheaper
        // than running the callee and failing on return.
        {
            const caller_frame = self.currentFrame();
            if (result_dst >= caller_frame.slot_count) {
                return VmError.OperandOutOfRange;
            }
        }
        // Validate the routine's metadata is internally
        // consistent (peer-AI turn 43, extended in 5e0): a
        // routine with `slot_count < fixed_arity` would underrun
        // on fixed param storage; a variadic routine additionally
        // needs `slot_count > fixed_arity` (room for the rest
        // slot). Indicates compiler bug or corrupt routine.
        // Use u32 for the addition to avoid overflow on
        // malformed routines with fixed_arity == maxInt(u16) and
        // variadic = true (peer-AI turn 50). Such routines are
        // bytecode corruption regardless; we want to surface
        // BytecodeCorruption, not an integer-overflow panic.
        const min_slots: u32 = @as(u32, callee_routine.fixed_arity) +
            @as(u32, if (callee_routine.variadic) 1 else 0);
        if (@as(u32, callee_routine.slot_count) < min_slots) {
            return VmError.BytecodeCorruption;
        }

        // Compute callee window per range-call ABI:
        //   callee.base_slot = caller.base_slot + call_base + 1
        // Read caller's base_slot before any stack/frames mutation.
        const caller_base: u32 = self.frames.items[caller_idx].base_slot;
        const callee_base: u32 = caller_base + call_base + 1;
        const callee_end: u32 = callee_base + callee_routine.slot_count;

        // Grow stack to fit the callee's full slot range. Args
        // are already at callee_base..callee_base+argc (windowed
        // from the caller). Locals/temps beyond args MUST be
        // initialized to nil even though that memory may already
        // exist as caller's high slots (peer-AI turn 42 catch:
        // GC roots / next-iteration reads need a valid Value
        // there, not stale caller data).
        if (callee_end > self.stack.items.len) {
            const grow_by: usize = callee_end - self.stack.items.len;
            try self.stack.appendNTimes(self.allocator, value_mod.nilValue(), grow_by);
            if (self.stack.items.len > self.stack_high_water) {
                self.stack_high_water = self.stack.items.len;
            }
        }

        // Step 5e: variadic-rest materialization. After this
        // block, slot[callee_base + fixed_arity] holds an
        // empty list (if argc == fixed_arity) or a cons list
        // of the excess args in their original order.
        //
        // CRITICAL ORDERING (peer-AI turn 49):
        //   (1) build the rest list FIRST, while excess-arg
        //       slots still hold the live values;
        //   (2) install at slot[fixed];
        //   (3) ONLY THEN reset the local slots to nil.
        // The earlier draft reset first, which clobbered the
        // excess-arg slots before construction read them and
        // produced rest lists of nils. The reset loop below
        // is now careful to start AT THE EARLIEST after the
        // rest slot (variadic: fixed+1) or after the args
        // (non-variadic: argc).
        if (callee_routine.variadic) {
            const heap = self.ensureHeap();
            var rest = list_mod.empty(heap) catch return VmError.OutOfMemory;
            const fixed: usize = callee_routine.fixed_arity;
            var j: usize = argc;
            while (j > fixed) {
                j -= 1;
                const arg = self.stack.items[@as(usize, callee_base) + j];
                rest = list_mod.cons(heap, arg, rest) catch return VmError.OutOfMemory;
            }
            self.stack.items[@as(usize, callee_base) + fixed] = rest;
        }

        // Reset dead slots to nil. Coverage (peer-AI turn 50):
        //   - Variadic: start at fixed_arity+1 (skip the rest
        //     slot, which was just written); end at
        //     max(callee_base + argc, callee_end). When
        //     argc > slot_count (common for variadic), excess-
        //     arg slots sit ABOVE the callee's logical frame
        //     but still inside the caller's backing stack —
        //     they hold dead post-cons values and must be
        //     nil'd for GC-root hygiene (once roots scan).
        //   - Non-variadic: start at argc (skip the live args).
        //     end at callee_end (slot_count).
        const reset_start: usize = if (callee_routine.variadic)
            @as(usize, callee_base) + callee_routine.fixed_arity + 1
        else
            @as(usize, callee_base) + argc;
        const args_end: usize = @as(usize, callee_base) + argc;
        const reset_end: usize = @max(args_end, callee_end);
        var i: usize = reset_start;
        while (i < reset_end) : (i += 1) {
            self.stack.items[i] = value_mod.nilValue();
        }

        // Snapshot the caller's already-incremented PC for the
        // callee's return_pc. The dispatch loop pre-increments
        // PC before invoking handlers, so caller_frame.pc here
        // points to the instruction following call:call.
        const caller_pc_after_call: u32 = self.frames.items[caller_idx].pc;

        // Append callee frame. After this point, `caller_frame`
        // pointers are invalidated.
        try self.frames.append(self.allocator, .{
            .routine = callee_routine,
            .base_slot = callee_base,
            .slot_count = callee_routine.slot_count,
            .pc = 0,
            .return_dst = result_dst,
            .return_pc = caller_pc_after_call,
            .upvalues = closure.upvalues,
        });
        if (self.frames.items.len > self.frame_high_water) {
            self.frame_high_water = self.frames.items.len;
        }
    }

    /// `call:return A=slot _ _` — read return value from
    /// `slot[A]`, then either halt (if top-level) or pop the
    /// callee frame and write the return value into the
    /// caller's `return_dst` slot.
    fn execCallReturn(self: *VM, inst: Inst) VmError!void {
        // Read the return value FIRST while the callee frame is
        // still active (peer-AI turn 42 ordering: shrinking the
        // stack or popping the frame before this read would
        // invalidate the slot pointer).
        const return_value = try self.resolve(inst.a);

        // Top-level return halts the VM and stores result.
        if (self.frames.items.len == 1) {
            self.result = return_value;
            self.halted = true;
            return;
        }

        // Non-top-level return.
        // Validate frame metadata BEFORE any mutation (peer-AI
        // turn 43): if `callee.return_dst` is invalid, popping
        // and shrinking first would partially corrupt VM state
        // before surfacing the error.
        const callee_idx = self.frames.items.len - 1;
        const caller_idx = callee_idx - 1;
        const callee_meta = self.frames.items[callee_idx];
        const caller_meta = self.frames.items[caller_idx];

        if (callee_meta.return_dst >= caller_meta.slot_count) {
            return VmError.OperandOutOfRange;
        }
        const caller_end: usize = @as(usize, caller_meta.base_slot) + caller_meta.slot_count;
        const absolute: usize = @as(usize, caller_meta.base_slot) + callee_meta.return_dst;
        if (absolute >= caller_end) return VmError.BytecodeCorruption;

        // Mutations from here on out are post-validation.
        _ = self.frames.pop().?;
        self.stack.shrinkRetainingCapacity(caller_end);
        self.stack.items[absolute] = return_value;
        self.frames.items[caller_idx].pc = callee_meta.return_pc;
    }

    /// `call:return-nil` — same as `call:return` with a nil
    /// return value, no operand resolution. Same validate-before-
    /// mutate discipline as `execCallReturn` (peer-AI turn 43).
    fn execCallReturnNil(self: *VM) VmError!void {
        if (self.frames.items.len == 1) {
            self.result = value_mod.nilValue();
            self.halted = true;
            return;
        }
        const callee_idx = self.frames.items.len - 1;
        const caller_idx = callee_idx - 1;
        const callee_meta = self.frames.items[callee_idx];
        const caller_meta = self.frames.items[caller_idx];

        if (callee_meta.return_dst >= caller_meta.slot_count) {
            return VmError.OperandOutOfRange;
        }
        const caller_end: usize = @as(usize, caller_meta.base_slot) + caller_meta.slot_count;
        const absolute: usize = @as(usize, caller_meta.base_slot) + callee_meta.return_dst;
        if (absolute >= caller_end) return VmError.BytecodeCorruption;

        _ = self.frames.pop().?;
        self.stack.shrinkRetainingCapacity(caller_end);
        self.stack.items[absolute] = value_mod.nilValue();
        self.frames.items[caller_idx].pc = callee_meta.return_pc;
    }

    // -------------------------------------------------------------------------
    // Group `closure` (VM.md §10.4)
    //
    // Step 5a1: only `make` is wired, and only with empty capture
    // descriptors (zero sources). 5b populates real descriptors;
    // 5c adds the placeholder-cell ops.
    // -------------------------------------------------------------------------

    fn execClosure(self: *VM, inst: Inst) VmError!void {
        const variant: Closure_ = @enumFromInt(inst.variant);
        switch (variant) {
            .make => try self.execClosureMake(inst),
            .box_local => try self.execClosureBoxLocal(inst),
            .get_cell => try self.execClosureGetCell(inst),
            .new_cell => try self.execClosureNewCell(inst),
            .init_cell => try self.execClosureInitCell(inst),
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// `closure:box-local A=slot _ _` — wrap slot[A]'s current
    /// value into a fresh, initialized UpvalCell. Replaces
    /// slot[A] with the cell-internal Value pointing at the cell.
    /// Per VM.md §6 (peer-AI turn 34, emission timing peer
    /// turn 40 lazy-boxing).
    ///
    /// Errors:
    ///   - InvalidCellState if slot[A] already holds a cell
    ///     pointer (double-box). Indicates compiler bug.
    fn execClosureBoxLocal(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        const ptr = try self.slotPtr(inst.a.index);
        const current = ptr.*;
        if (current.kind() == value_mod.Kind.cell_internal) {
            return VmError.InvalidCellState;
        }
        const cell_value = self.allocCell(current, true) catch return VmError.OutOfMemory;
        // ptr may have been invalidated by stack growth inside
        // allocCell? No — allocCell only touches runtime_arena,
        // not vm.stack. Safe to reuse ptr.
        ptr.* = cell_value;
    }

    /// `closure:get-cell A=dst_slot B=cell_slot _` — read the
    /// contents of an UpvalCell whose pointer lives in slot[B];
    /// write to slot[A]. Used by same-frame reads of a boxed
    /// local (peer-AI turn 34).
    ///
    /// Errors:
    ///   - ExpectedCell if slot[B] doesn't hold a cell pointer.
    ///   - UninitializedCell if cell.initialized = false.
    fn execClosureGetCell(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.b.kind != .slot) return VmError.InvalidOperandKind;
        const cell_v = (try self.slotPtr(inst.b.index)).*;
        const cell = try VM.asCell(cell_v);
        if (!cell.initialized) return VmError.UninitializedCell;
        try self.store(inst.a, cell.value);
    }

    /// `closure:new-cell A=slot _ _` — allocate an
    /// uninitialized UpvalCell, store its cell-internal Value
    /// at slot[A]. Step 5c: used by `letfn*` lowering and
    /// named `fn*` self-reference to allocate placeholder
    /// cells that subsequent `closure:make` instructions
    /// capture (raw cell pointer copied), and that
    /// `closure:init-cell` later fills in with the constructed
    /// closure value.
    ///
    /// Per VM.md §6 (peer-AI turn 34). The cell starts with
    /// `initialized = false`; reading it via U-operand or
    /// `closure:get-cell` before init traps `:uninitialized-cell`.
    fn execClosureNewCell(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        // Initial value doesn't matter (it'll be overwritten by
        // init-cell before any read). Use nil as a sentinel
        // recognizable in dumps.
        const cell_v = self.allocCell(value_mod.nilValue(), false) catch return VmError.OutOfMemory;
        try self.store(inst.a, cell_v);
    }

    /// `closure:init-cell A=cell_slot B=value_op _` — fill an
    /// uninitialized cell with a value, flip `initialized = true`.
    /// Step 5c: used by `letfn*` and named `fn*` lowerings to
    /// finalize placeholder cells with the constructed closure
    /// value, after `closure:make` has constructed the closure
    /// (which captured the still-uninitialized cell).
    ///
    /// Per VM.md §6 (peer-AI turn 34).
    ///
    /// Errors:
    ///   - ExpectedCell if slot[A] doesn't hold a cell pointer.
    ///   - InvalidCellState if the cell is already initialized
    ///     (double-init). Indicates compiler bug.
    fn execClosureInitCell(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        // Validate destination cell state BEFORE resolving B
        // (peer-AI turn 46): the destination contract is the
        // primary contract of init-cell. Reading a malformed
        // source operand before checking the cell would surface
        // the wrong error (e.g., UninitializedCell on the
        // source upvalue instead of InvalidCellState on the
        // already-initialized destination).
        const cell_v = (try self.slotPtr(inst.a.index)).*;
        const cell = try VM.asCell(cell_v);
        if (cell.initialized) return VmError.InvalidCellState;
        // B may be any operand kind that resolve() accepts.
        const value = try self.resolve(inst.b);
        cell.value = value;
        cell.initialized = true;
    }

    /// `closure:make A=prototype_const B=cap_desc_imm C=result_slot`
    /// per VM.md §6 (peer-AI turn 34, descriptor-based encoding).
    fn execClosureMake(self: *VM, inst: Inst) VmError!void {
        // Operand kind validation: A must be a constant (typed
        // pool requires .routine variant; resolve below catches
        // a .value mismatch). C must be a slot. B is raw-index
        // (kind ignored per §4.5).
        if (inst.a.kind != .constant) return VmError.InvalidOperandKind;
        if (inst.c.kind != .slot) return VmError.InvalidOperandKind;

        const frame = self.currentFrame();
        const consts = frame.routine.consts;
        if (inst.a.index >= consts.len) return VmError.OperandOutOfRange;

        const child_routine = switch (consts[inst.a.index]) {
            .routine => |r| r,
            // mov:load-const with .routine raises InvalidOperandKind;
            // closure:make with .value is the symmetric error.
            .value => return VmError.InvalidOperandKind,
        };

        // Capture descriptor lookup (B operand, raw index).
        const cap_idx: u32 = inst.b.index;
        if (cap_idx >= frame.routine.capture_descs.len) {
            return VmError.OperandOutOfRange;
        }
        const desc = frame.routine.capture_descs[cap_idx];

        // Source count must match child routine's expectation.
        if (desc.sources.len != child_routine.upvalue_count) {
            return VmError.CaptureCountMismatch;
        }

        // Step 5b (peer-AI turn 34 descriptor encoding): for
        // each capture source, read the raw *UpvalCell pointer.
        //   .local_cell_slot(s): slot[s] must hold a cell-
        //     internal Value (boxed by prior closure:box-local).
        //   .inherited_upvalue(u): caller's frame.upvalues[u]
        //     is already a *UpvalCell pointer — copy directly.
        // Construct the closure's upvalues[] by appending each
        // resolved cell pointer in descriptor order.
        const arena = self.runtime_arena.allocator();
        var upvalues: []*UpvalCell = undefined;
        if (desc.sources.len == 0) {
            upvalues = &.{};
        } else {
            upvalues = arena.alloc(*UpvalCell, desc.sources.len) catch
                return VmError.OutOfMemory;
            for (desc.sources, 0..) |source, i| {
                upvalues[i] = switch (source) {
                    .local_cell_slot => |s| blk: {
                        const cell_v = (try self.slotPtr(s)).*;
                        // Must be a cell pointer (peer-AI turn 34:
                        // `:expected-cell` trap). The compiler's
                        // lazy-boxing path guarantees this in
                        // well-formed bytecode; malformed bytecode
                        // (e.g., descriptor source referencing an
                        // un-boxed slot) traps here.
                        break :blk try VM.asCell(cell_v);
                    },
                    .inherited_upvalue => |u| blk: {
                        if (u >= frame.upvalues.len) return VmError.UpvalueOutOfRange;
                        // Direct raw-cell access — NOT via
                        // resolve(u), which would deref to
                        // cell-contents (peer-AI turn 34 raw-vs-
                        // contents distinction).
                        break :blk frame.upvalues[u];
                    },
                };
            }
        }

        // Allocate the closure with the populated upvalue array.
        // (Allocator failure surfaces as VmError.OutOfMemory.)
        const closure_v = self.allocClosure(child_routine, upvalues) catch
            return VmError.OutOfMemory;

        try self.store(inst.c, closure_v);
    }


    // -------------------------------------------------------------------------
    // Group `math` (VM.md §10 #3 — PLAN §12.3 group 2)
    //
    // Step #2 (COMPILER.md §10 #2): wires `math:add` for fixnum+fixnum
    // only. Floats, bignums, and cross-type promotion are deferred to
    // subsequent commits.
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Group `jump` (VM.md §10.5 — PLAN §12.3 group 0)
    //
    // Step #3 (COMPILER.md §10 #3): all three v1 variants wired.
    // Jump targets are absolute instruction indices within the
    // current routine's `code` array. Per VM.md §4.5, the jump
    // target operand is a "raw index" (kind ignored, index is
    // the data); the encoding convention is `Operand.jump(N)`
    // where N is the destination PC.
    // -------------------------------------------------------------------------

    fn execJump(self: *VM, inst: Inst) VmError!void {
        const variant: Jump = @enumFromInt(inst.variant);
        switch (variant) {
            .jmp => {
                // jump:jmp A=target _ _   ; pc := A.index
                try self.applyJump(inst.a);
            },
            .if_true => {
                // jump:if-true A=target B=test _   ; if truthy(B) pc := A.index
                const test_v = try self.resolve(inst.b);
                if (test_v.isTruthy()) {
                    try self.applyJump(inst.a);
                }
            },
            .if_false => {
                // jump:if-false A=target B=test _  ; if falsy(B) pc := A.index
                const test_v = try self.resolve(inst.b);
                if (test_v.isFalsy()) {
                    try self.applyJump(inst.a);
                }
            },
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// Apply a jump-target operand to the current frame's PC.
    ///
    /// Validates two things (peer-AI turn 37 hardening):
    ///   1. `target.kind` is `.jump`. Permissively accepting other
    ///      kinds (e.g., `.slot`) here turns "stale placeholder
    ///      bytecode" into "infinite loop reading slot 0" — exactly
    ///      the bug that almost shipped in step #3. Requiring the
    ///      `.jump` kind turns that class of corruption into a
    ///      clean `InvalidOperandKind` at the type level.
    ///   2. The target PC is strictly within the routine's code
    ///      range. A target equal to `code.len` is illegal because
    ///      the next dispatch would surface BytecodeExhausted.
    fn applyJump(self: *VM, target: Operand) VmError!void {
        if (target.kind != .jump) return VmError.InvalidOperandKind;
        const pc: u32 = @intCast(target.index);
        const frame = self.currentFrame();
        if (pc >= frame.routine.code.len) return VmError.OperandOutOfRange;
        frame.pc = pc;
    }

    fn execMath(self: *VM, inst: Inst) VmError!void {
        const variant: Math = @enumFromInt(inst.variant);
        switch (variant) {
            .add => {
                // math:add a b c   ;  slot[a] = resolve(b) + resolve(c)
                // Resolve BOTH source operands BEFORE storing so that
                // dst/src aliasing (e.g., math:add s0, s0, c0) is
                // correct (peer-AI turn 33).
                const lhs = try self.resolve(inst.b);
                const rhs = try self.resolve(inst.c);
                const sum = try addNumbers(lhs, rhs);
                try self.store(inst.a, sum);
            },
            // Known but not yet implemented in this commit.
            .sub, .mul, .div, .idiv, .mod, .pow, .neg, .abs => return VmError.UnimplementedOpcode,
            _ => return VmError.BytecodeCorruption,
        }
    }

    // -------------------------------------------------------------------------
    // Group `cmp` (VM.md §10 #1)
    // -------------------------------------------------------------------------

    fn execCmp(self: *VM, inst: Inst) VmError!void {
        const variant: Cmp = @enumFromInt(inst.variant);
        switch (variant) {
            .lt => {
                // cmp:lt a b c   ;  slot[a] = (resolve(b) < resolve(c)) as bool
                // Step 5d0: fixnum-only. Non-fixnum operands trap
                // :kind-mismatch (matches math:add discipline).
                // Result is a `Value` of kind `.bool_`.
                const lhs = try self.resolve(inst.b);
                const rhs = try self.resolve(inst.c);
                const result = try ltFixnums(lhs, rhs);
                try self.store(inst.a, value_mod.fromBool(result));
            },
            // Known but not yet implemented in this commit.
            .lte, .gt, .gte, .eq_num => return VmError.UnimplementedOpcode,
            _ => return VmError.BytecodeCorruption,
        }
    }

    // -------------------------------------------------------------------------
    // Group `var` (VM.md §10 #6) — step #6a wires `load_var` only
    // -------------------------------------------------------------------------

    fn execVar(self: *VM, inst: Inst) VmError!void {
        const variant: VarOp = @enumFromInt(inst.variant);
        switch (variant) {
            .load_var => try self.execVarLoadVar(inst),
            .store_var => try self.execVarStoreVar(inst),
            .var_object => try self.execVarVarObject(inst),
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// `var:load-var A=dst_slot B=var(index) _` — read the Var
    /// at `routine.var_table[B.index]` and store its root value
    /// into `slot[A]`. Step #6a. Traps `:unbound-var` if the
    /// Var has never been bound by `def`.
    ///
    /// Semantically equivalent to `mov:move A=slot, B=var(idx)`
    /// (the V operand kind goes through the same resolve()
    /// path). The dedicated opcode exists for symmetry with
    /// `var:store-var` (#6b) and for diagnostic clarity in
    /// disassembly.
    fn execVarLoadVar(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.b.kind != .var_) return VmError.InvalidOperandKind;
        const v = try self.resolve(inst.b);
        try self.store(inst.a, v);
    }

    /// `var:store-var A=dst_slot B=var(index) C=value_op` —
    /// set `routine.var_table[B.index].root = resolve(C)`,
    /// mark `bound = true`, and write the Var object (a Value
    /// of kind `.var_`) into `slot[A]`. Step #6b.
    ///
    /// Returning the Var (not the value) matches Clojure's
    /// `def` semantics: `(def x 5)` evaluates to the Var
    /// `#'x`. Rebinding the same name updates the SAME Var in
    /// place (identity-stable), so existing closures that
    /// captured `x`'s Var continue to see the new value.
    fn execVarStoreVar(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.b.kind != .var_) return VmError.InvalidOperandKind;
        const var_table = self.currentFrame().routine.var_table;
        if (inst.b.index >= var_table.len) return VmError.OperandOutOfRange;
        const target = var_table[inst.b.index];
        const new_value = try self.resolve(inst.c);
        target.root = new_value;
        target.bound = true;
        try self.store(inst.a, VM.varToValue(target));
    }

    /// `var:var-object A=dst_slot B=var(index) _` — write the
    /// Var object itself (Value of kind `.var_`) into
    /// `slot[A]`. Does NOT trap on unbound; taking a reference
    /// to an unbound Var is legal (Clojure's `(var x)` /
    /// `#'x`). Step #6b.
    fn execVarVarObject(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.b.kind != .var_) return VmError.InvalidOperandKind;
        const var_table = self.currentFrame().routine.var_table;
        if (inst.b.index >= var_table.len) return VmError.OperandOutOfRange;
        const target = var_table[inst.b.index];
        try self.store(inst.a, VM.varToValue(target));
    }

    // -------------------------------------------------------------
    // Group #7: `coll` — collection construction (step #8c.1)
    // -------------------------------------------------------------
    //
    // Operand convention (range ABI, mirrors call:call):
    //   A = slot   — first arg slot (must be `.slot` kind)
    //   B = raw    — argc (raw u12 immediate, kind ignored per §4.5)
    //   C = slot   — destination slot
    //
    // Both opcodes allocate via `self.ensureHeap()` (arena-backed
    // through Phase 2; GC integration in Phase 4 will require
    // rooting partial results during construction — see GC TODO
    // comments below).

    fn execColl(self: *VM, inst: Inst) VmError!void {
        const variant: CollOp = @enumFromInt(inst.variant);
        switch (variant) {
            .list => try self.execCollList(inst),
            .concat => try self.execCollConcat(inst),
            .vector => try self.execCollVector(inst),
            .map => try self.execCollMap(inst),
            .set => try self.execCollSet(inst),
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// `coll:list A=arg_base B=argc C=dst` — read argc values
    /// from `stack[arg_base .. arg_base+argc]` and build a list
    /// right-to-left via `list_mod.cons`. Step #8c.1.
    fn execCollList(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.c.kind != .slot) return VmError.InvalidOperandKind;
        const arg_base: u12 = inst.a.index;
        const argc: u12 = inst.b.index; // raw immediate (operand kind ignored)
        const dst: u12 = inst.c.index;

        // Validate the arg block is within the current frame's
        // logical slot range. Catch malformed bytecode early.
        const frame = self.currentFrame();
        const last_arg_slot: u32 = @as(u32, arg_base) + @as(u32, argc);
        if (last_arg_slot > frame.slot_count) return VmError.OperandOutOfRange;

        const heap = self.ensureHeap();
        // GC TODO (peer-AI turn 58 §D3): once `list_mod.cons`
        // can collect, the partial `result` list must be a GC
        // root for the duration of this loop. For arena-backed
        // allocation (Phase 2), no rooting needed.
        var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
        var i: usize = argc;
        while (i > 0) {
            i -= 1;
            // slotPtr is read-only here; arg slots are within
            // the same frame, so the pointer is valid for one
            // step. We deref into a Value (16 bytes) immediately
            // to avoid holding *Value across the cons call.
            const arg_idx: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
            const arg_val = (try self.slotPtr(arg_idx)).*;
            result = list_mod.cons(heap, arg_val, result) catch return VmError.OutOfMemory;
        }
        try self.store(.{ .kind = .slot, .index = dst }, result);
    }

    /// `coll:concat A=arg_base B=argc C=dst` — each arg must
    /// be a list Value; result is the left-to-right concat.
    /// Strategy (peer-AI turn 58 §"Missing trap #4"): traverse
    /// each input list, collect elements into a temp slice,
    /// then build the result right-to-left via cons. Avoids
    /// recursive append on singly-linked lists. Step #8c.1.
    fn execCollConcat(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.c.kind != .slot) return VmError.InvalidOperandKind;
        const arg_base: u12 = inst.a.index;
        const argc: u12 = inst.b.index;
        const dst: u12 = inst.c.index;

        const frame = self.currentFrame();
        const last_arg_slot: u32 = @as(u32, arg_base) + @as(u32, argc);
        if (last_arg_slot > frame.slot_count) return VmError.OperandOutOfRange;

        const heap = self.ensureHeap();

        // First pass: collect every element from every list
        // into a temp ArrayList. We need this because we
        // don't know the total length upfront, and singly-
        // linked lists can only be built efficiently right-
        // to-left. Empty concat → empty list.
        var elements = std.ArrayList(Value).empty;
        defer elements.deinit(self.runtime_arena.allocator());

        var i: usize = 0;
        while (i < argc) : (i += 1) {
            const arg_idx: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
            const arg_val = (try self.slotPtr(arg_idx)).*;
            // Validate: each arg must be a list.
            if (arg_val.kind() != .list) return VmError.KindMismatch;
            // Walk the list, collecting elements.
            var node = arg_val;
            while (node.kind() == .list and !list_mod.isEmpty(node)) {
                const head = list_mod.head(node);
                try elements.append(self.runtime_arena.allocator(), head);
                node = list_mod.tail(node);
            }
        }

        // Second pass: build result right-to-left.
        // GC TODO (peer-AI turn 58 §D3): partial result needs
        // rooting once cons can collect.
        var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
        var k: usize = elements.items.len;
        while (k > 0) {
            k -= 1;
            result = list_mod.cons(heap, elements.items[k], result) catch return VmError.OutOfMemory;
        }
        try self.store(.{ .kind = .slot, .index = dst }, result);
    }

    /// `coll:vector A=arg_base B=argc C=dst` — build a
    /// persistent vector from argc slot values via
    /// `vector_mod.fromSlice`. Step #8c.3.
    fn execCollVector(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.c.kind != .slot) return VmError.InvalidOperandKind;
        const arg_base: u12 = inst.a.index;
        const argc: u12 = inst.b.index;
        const dst: u12 = inst.c.index;

        const frame = self.currentFrame();
        const last_arg_slot: u32 = @as(u32, arg_base) + @as(u32, argc);
        if (last_arg_slot > frame.slot_count) return VmError.OperandOutOfRange;

        const heap = self.ensureHeap();
        if (argc == 0) {
            const result = vector_mod.empty(heap) catch return VmError.OutOfMemory;
            try self.store(.{ .kind = .slot, .index = dst }, result);
            return;
        }
        // Collect elements into a temp slice then hand to
        // fromSlice. The slice escapes the loop, so we allocate
        // from runtime_arena.
        var elems = std.ArrayList(Value).empty;
        defer elems.deinit(self.runtime_arena.allocator());
        try elems.ensureTotalCapacity(self.runtime_arena.allocator(), argc);
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            const arg_idx: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
            const arg_val = (try self.slotPtr(arg_idx)).*;
            try elems.append(self.runtime_arena.allocator(), arg_val);
        }
        // GC TODO (peer-AI turn 58 §D3): vector node allocation
        // can collect once GC integrates; the temp elems slice
        // must be rooted during the build.
        const result = vector_mod.fromSlice(heap, elems.items) catch return VmError.OutOfMemory;
        try self.store(.{ .kind = .slot, .index = dst }, result);
    }

    /// `coll:map A=arg_base B=argc C=dst` — build a persistent
    /// map from argc slot values interpreted as flat k,v,k,v,...
    /// pairs. argc MUST be even. Iterates left-to-right calling
    /// `champ.mapAssoc`; later duplicate keys overwrite earlier
    /// (Clojure semantics, peer-AI turn 65 §2). Phase 3.1.
    fn execCollMap(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.c.kind != .slot) return VmError.InvalidOperandKind;
        const arg_base: u12 = inst.a.index;
        const argc: u12 = inst.b.index;
        const dst: u12 = inst.c.index;

        if (argc % 2 != 0) return VmError.BytecodeCorruption;

        const frame = self.currentFrame();
        const last_arg_slot: u32 = @as(u32, arg_base) + @as(u32, argc);
        if (last_arg_slot > frame.slot_count) return VmError.OperandOutOfRange;

        const heap = self.ensureHeap();
        var result = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
        // GC TODO (peer-AI turn 58 §D3): each mapAssoc may
        // collect; partial result must be a root once GC
        // integrates. Arena-backed for Phase 2/3.
        var i: usize = 0;
        while (i < argc) : (i += 2) {
            const k_idx: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
            const v_idx: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i + 1)));
            const k = (try self.slotPtr(k_idx)).*;
            const v = (try self.slotPtr(v_idx)).*;
            result = champ_mod.mapAssoc(
                heap,
                result,
                k,
                v,
                &dispatch_mod.hashValue,
                &dispatch_mod.equal,
            ) catch return VmError.OutOfMemory;
        }
        try self.store(.{ .kind = .slot, .index = dst }, result);
    }

    /// `coll:set A=arg_base B=argc C=dst` — build a persistent
    /// set from argc slot values. Duplicates collapse (set
    /// semantics, peer-AI turn 65 §3). Phase 3.1.
    fn execCollSet(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.c.kind != .slot) return VmError.InvalidOperandKind;
        const arg_base: u12 = inst.a.index;
        const argc: u12 = inst.b.index;
        const dst: u12 = inst.c.index;

        const frame = self.currentFrame();
        const last_arg_slot: u32 = @as(u32, arg_base) + @as(u32, argc);
        if (last_arg_slot > frame.slot_count) return VmError.OperandOutOfRange;

        const heap = self.ensureHeap();
        var result = champ_mod.setEmpty(heap) catch return VmError.OutOfMemory;
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            const arg_idx: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
            const v = (try self.slotPtr(arg_idx)).*;
            result = champ_mod.setConj(
                heap,
                result,
                v,
                &dispatch_mod.hashValue,
                &dispatch_mod.equal,
            ) catch return VmError.OutOfMemory;
        }
        try self.store(.{ .kind = .slot, .index = dst }, result);
    }

    // -------------------------------------------------------------
    // Group #11: `ctrl` — try / catch / throw (step #9.1)
    // -------------------------------------------------------------
    //
    // Per VM.md §12 + peer-AI turn 59. v1 covers user-thrown
    // values; VM-detected errors (KindMismatch, etc.) are NOT
    // catchable in this commit (deferred to post-#10 once the
    // error reporting layer can convert them to user Values).
    // finally is reserved for #9.2.

    fn execCtrl(self: *VM, inst: Inst) VmError!void {
        const variant: CtrlOp = @enumFromInt(inst.variant);
        switch (variant) {
            .try_enter => try self.execCtrlTryEnter(inst),
            .try_exit => try self.execCtrlTryExit(inst),
            .throw_ => try self.execCtrlThrow(inst),
            .finally_exit => try self.execCtrlFinallyExit(inst),
            .halt_ => return VmError.UnimplementedOpcode,
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// `ctrl:try-enter A=catch_pc B=binding_slot C=finally_pc?` —
    /// push a try handler onto the global handler stack.
    /// catch_pc is absolute within the current routine.
    /// binding_slot is where the thrown value will be stored.
    ///
    /// Step #9.2: C may now carry an absolute finally_pc as a
    /// `.jump` operand, OR remain `.unused` for try forms
    /// without a finally clause.
    fn execCtrlTryEnter(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .jump) return VmError.InvalidOperandKind;
        if (inst.b.kind != .slot) return VmError.InvalidOperandKind;
        const finally_pc: ?u32 = switch (inst.c.kind) {
            .unused => null,
            .jump => inst.c.index,
            else => return VmError.InvalidOperandKind,
        };

        const frame_index = self.frames.items.len - 1;
        const frame = self.currentFrame();
        try self.handlers.append(self.allocator, .{
            .kind = .try_,
            .frame_index = frame_index,
            .catch_pc = inst.a.index,
            .binding_slot = inst.b.index,
            .finally_pc = finally_pc,
            .saved_stack_len = @as(usize, frame.base_slot) + @as(usize, frame.slot_count),
        });
    }

    /// `ctrl:try-exit A=post_pc B=unused C=unused` — pop the
    /// current handler (must belong to this frame).
    ///
    /// Step #9.1: jumps directly to post_pc.
    /// Step #9.2: if the popped handler had a finally, push a
    /// `.normal(post_pc)` FinallyContinuation and jump to
    /// finally_pc instead. The finally-exit opcode pops the
    /// continuation and jumps to post_pc.
    fn execCtrlTryExit(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .jump) return VmError.InvalidOperandKind;
        const post_pc: u32 = inst.a.index;

        if (self.handlers.items.len == 0) return VmError.InvalidHandlerState;
        const top = self.handlers.items[self.handlers.items.len - 1];
        const frame_index = self.frames.items.len - 1;
        if (top.frame_index != frame_index) return VmError.InvalidHandlerState;

        _ = self.handlers.pop();
        const frame = self.currentFrame();
        if (top.finally_pc) |fpc| {
            try self.finally_stack.append(self.allocator, .{
                .frame_index = frame_index,
                .reason = .{ .normal = post_pc },
            });
            frame.pc = fpc;
        } else {
            frame.pc = post_pc;
        }
    }

    /// `ctrl:finally-exit` (step #9.2) — pop the topmost
    /// FinallyContinuation and dispatch on its reason.
    fn execCtrlFinallyExit(self: *VM, _: Inst) VmError!void {
        if (self.finally_stack.items.len == 0) return VmError.InvalidHandlerState;
        const cont = self.finally_stack.pop().?;
        const frame_index = self.frames.items.len - 1;
        if (cont.frame_index != frame_index) return VmError.InvalidHandlerState;
        switch (cont.reason) {
            .normal => |post_pc| {
                const frame = self.currentFrame();
                frame.pc = post_pc;
            },
            .throwing => |value| {
                try self.unwindThrow(value);
            },
        }
    }

    /// `ctrl:throw A=value_operand B=unused C=unused` — throw
    /// the resolved value. Walks the handler stack top-to-bottom
    /// looking for a `.try_` handler. If found:
    ///   1. Replace the handler with a `.cleanup` (so the catch
    ///      body's own throw isn't re-caught by the same
    ///      handler — peer-AI turn 59 §"Missing trap 1").
    ///   2. Unwind frames above the handler's frame_index.
    ///   3. Shrink stack to saved_stack_len.
    ///   4. Store the thrown value into binding_slot.
    ///   5. Jump to catch_pc.
    ///
    /// If no `.try_` handler exists anywhere, stores the thrown
    /// value into `VM.unhandled_throw` and returns
    /// `VmError.UncaughtThrow`.
    fn execCtrlThrow(self: *VM, inst: Inst) VmError!void {
        const value = try self.resolve(inst.a);
        try self.unwindThrow(value);
    }

    /// Walk the handler stack top-down looking for the topmost
    /// handler that catches a throw. Per step #9.2:
    ///   - `.try_` handlers catch (jump to catch_pc).
    ///   - `.cleanup` handlers do NOT catch but DO run their
    ///     finally (jump to finally_pc with .throwing
    ///     continuation).
    ///   - `.cleanup` with no finally is just bookkeeping —
    ///     skip it.
    /// Returns the index of the matching handler in
    /// `self.handlers`, or null if nothing matches.
    fn findThrowTarget(self: *VM) ?usize {
        var i: usize = self.handlers.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.handlers.items[i];
            switch (h.kind) {
                .try_ => return i,
                .cleanup => if (h.finally_pc != null) return i,
            }
        }
        return null;
    }

    /// Common throw-unwind logic. Used by `execCtrlThrow` and
    /// by `finally-exit`'s `.throwing` continuation.
    fn unwindThrow(self: *VM, value: Value) VmError!void {
        const handler_idx = self.findThrowTarget() orelse {
            // No matching handler anywhere — uncaught.
            self.unhandled_throw = value;
            return VmError.UncaughtThrow;
        };
        const matched = self.handlers.items[handler_idx];

        // Discard any handlers above the matched one (cleanup
        // records from inner scopes that we passed over —
        // they're no longer reachable since their try is
        // unwinding through us).
        self.handlers.shrinkRetainingCapacity(handler_idx);

        // Unwind frames above the matched handler's frame.
        // Per peer-AI turn 59 §D8: do NOT write to caller
        // return slots, just pop. (Normal `call:return` writes
        // to caller's return_dst; throw bypasses that.)
        while (self.frames.items.len - 1 > matched.frame_index) {
            _ = self.frames.pop();
        }

        // Shrink stack back to the matched frame's logical end.
        if (self.stack.items.len > matched.saved_stack_len) {
            self.stack.shrinkRetainingCapacity(matched.saved_stack_len);
        }

        const frame = self.currentFrame();

        switch (matched.kind) {
            .try_ => {
                // Push a cleanup handler in place of the original
                // try (peer-AI turn 59 §D5 "classic trap" fix).
                // This protects the catch body from being re-caught
                // by its own handler and gives the catch body's
                // `try-exit` something to pop. The cleanup INHERITS
                // the try's finally_pc so a throw inside the catch
                // body still runs the finally.
                try self.handlers.append(self.allocator, .{
                    .kind = .cleanup,
                    .frame_index = matched.frame_index,
                    .catch_pc = 0,
                    .binding_slot = 0,
                    .finally_pc = matched.finally_pc,
                    .saved_stack_len = matched.saved_stack_len,
                });

                // Store thrown value into the handler's binding_slot.
                if (matched.binding_slot >= frame.slot_count) {
                    return VmError.InvalidHandlerState;
                }
                const ptr = try self.slotPtr(matched.binding_slot);
                ptr.* = value;

                // Jump to catch entry.
                frame.pc = matched.catch_pc;
            },
            .cleanup => {
                // The popped record was a cleanup with finally.
                // Push a .throwing continuation so the finally
                // resumes the throw after completion.
                const fpc = matched.finally_pc orelse return VmError.InvalidHandlerState;
                try self.finally_stack.append(self.allocator, .{
                    .frame_index = matched.frame_index,
                    .reason = .{ .throwing = value },
                });
                frame.pc = fpc;
            },
        }
    }
};

/// Phase 3.0c: stable taxonomy mapping recoverable VmError
/// variants to user-visible keyword names. Per VM.md §13
/// "Recoverable via try/catch" column + peer-AI turn 62
/// recoverable-list.
///
/// Returns null for unrecoverable errors — bytecode
/// corruption, OOM, handler-state malformation, etc. Those
/// propagate to the caller unchanged.
fn vmErrorToKeywordName(err: VmError) ?[]const u8 {
    return switch (err) {
        // Recoverable per VM.md §13.
        VmError.KindMismatch => "kind-mismatch",
        VmError.ArityMismatch => "arity-mismatch",
        VmError.NotCallable => "not-callable",
        VmError.UnboundVar => "unbound-var",
        VmError.IntegerOverflow => "integer-overflow",
        // Unrecoverable: bytecode corruption / VM-internal /
        // OOM / already-a-user-throw / unimplemented.
        VmError.UncaughtThrow,
        VmError.BytecodeCorruption,
        VmError.BytecodeExhausted,
        VmError.UnimplementedOpcode,
        VmError.OperandOutOfRange,
        VmError.InvalidOperandKind,
        VmError.OutOfMemory,
        VmError.CaptureCountMismatch,
        VmError.UpvalueOutOfRange,
        VmError.ExpectedCell,
        VmError.InvalidCellState,
        VmError.UninitializedCell,
        VmError.CallBlockOutOfRange,
        VmError.InvalidHandlerState,
        VmError.Halt,
        => null,
    };
}

/// Numeric addition for the math:add opcode. Step #2 supports
/// only fixnum+fixnum; widening lands in subsequent commits.
///
/// Future-target factoring (peer-AI turn 33): when math:sub and
/// friends land, this and its siblings extract into a `src/numeric.zig`
/// module that both vm.zig and dispatch.zig can call. Avoiding a
/// vm→dispatch dependency now keeps the import graph clean and
/// matches the "low-level semantics shared by VM + dispatch" target
/// shape.
///
/// Returns:
///   - `IntegerOverflow` if the i64-extended sum exceeds the i48
///     fixnum range. Bignum promotion (PLAN §6.3) is the eventual
///     behavior; until bignum arithmetic Scope B lands, the trap
///     is preferable to silent precision loss.
///   - `KindMismatch` if either operand is not a fixnum (in v1
///     this includes float — float + fixnum support arrives with
///     the float-arithmetic commit). Reuses VM.md §13's existing
///     `:kind-mismatch` taxonomy rather than introducing a parallel
///     `:type-error` category.
fn addNumbers(lhs: value_mod.Value, rhs: value_mod.Value) VmError!value_mod.Value {
    if (!lhs.isFixnum() or !rhs.isFixnum()) return VmError.KindMismatch;
    const a = lhs.asFixnum();
    const b = rhs.asFixnum();
    // i64 add never overflows from i48-range operands (max sum is
    // 2 * (2^47 - 1) which fits comfortably in i64). The fixnum
    // range check below catches the i48-overflow case.
    const sum = a + b;
    return value_mod.fromFixnum(sum) orelse VmError.IntegerOverflow;
}

/// Fixnum-only less-than comparison for the cmp:lt opcode.
/// Step 5d0: only fixnum<fixnum is supported; mixed-numeric
/// (fixnum vs float) and bignum comparisons land later with
/// the wider numeric tower. Non-fixnum operands raise
/// `KindMismatch` — same discipline as `addNumbers`.
fn ltFixnums(lhs: value_mod.Value, rhs: value_mod.Value) VmError!bool {
    if (!lhs.isFixnum() or !rhs.isFixnum()) return VmError.KindMismatch;
    return lhs.asFixnum() < rhs.asFixnum();
}

// =============================================================================
// Convenience helpers for hand-assembling bytecode in tests.
// =============================================================================

pub fn makeRoutine(
    code: []const Inst,
    consts: []const Const,
    slot_count: u16,
    name: []const u8,
) Routine {
    return .{
        .code = code,
        .consts = consts,
        .slot_count = slot_count,
        .name = name,
    };
}

/// Test-ergonomics helper: wrap a `Value` in `Const.value`.
/// Lets test fixtures write `cval(value_mod.fromFixnum(7).?)`
/// instead of `.{ .value = value_mod.fromFixnum(7).? }` for
/// each constant-pool entry.
pub fn cval(v: Value) Const {
    return .{ .value = v };
}

/// Test-ergonomics helper: wrap a `*const Routine` in
/// `Const.routine`. Symmetric with `cval`.
pub fn croutine(r: *const Routine) Const {
    return .{ .routine = r };
}

/// Encoding helpers. Every opcode used in this commit has a
/// corresponding helper. Keeps hand-assembly readable.
pub const asm_ = struct {
    pub fn loadConst(slot_dst: u12, const_src: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.load_const,
            Operand.slot(slot_dst),
            Operand.constant(const_src),
            Operand.none,
        );
    }

    pub fn move(slot_dst: u12, slot_src: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.move,
            Operand.slot(slot_dst),
            Operand.slot(slot_src),
            Operand.none,
        );
    }

    pub fn loadNil(slot_dst: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.load_nil,
            Operand.slot(slot_dst),
            Operand.none,
            Operand.none,
        );
    }

    pub fn loadTrue(slot_dst: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.load_true,
            Operand.slot(slot_dst),
            Operand.none,
            Operand.none,
        );
    }

    pub fn loadFalse(slot_dst: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.load_false,
            Operand.slot(slot_dst),
            Operand.none,
            Operand.none,
        );
    }

    pub fn returnSlot(slot_src: u12) Inst {
        return Inst.primary(
            .call,
            Call.@"return",
            Operand.slot(slot_src),
            Operand.none,
            Operand.none,
        );
    }

    pub fn returnNil() Inst {
        return Inst.primary(
            .call,
            Call.return_nil,
            Operand.none,
            Operand.none,
            Operand.none,
        );
    }

    /// math:add a b c   ;  slot[a] = resolve(b) + resolve(c)
    /// `b` and `c` may be any kind that `resolve` accepts (slot
    /// or constant in this commit).
    pub fn mathAdd(slot_dst: u12, lhs: Operand, rhs: Operand) Inst {
        return Inst.primary(
            .math,
            Math.add,
            Operand.slot(slot_dst),
            lhs,
            rhs,
        );
    }

    /// cmp:lt dst lhs rhs   ; slot[dst] := bool(resolve(lhs) < resolve(rhs))
    /// Fixnum-only in step 5d0; non-fixnum operands trap
    /// :kind-mismatch.
    pub fn cmpLt(slot_dst: u12, lhs: Operand, rhs: Operand) Inst {
        return Inst.primary(
            .cmp,
            Cmp.lt,
            Operand.slot(slot_dst),
            lhs,
            rhs,
        );
    }

    /// var:load-var dst var_idx  ; slot[dst] := routine.var_table[var_idx].root
    /// Step #6a. Traps :unbound-var if the Var has never been
    /// bound by `def`.
    pub fn varLoadVar(slot_dst: u12, var_idx: u12) Inst {
        return Inst.primary(
            .var_,
            VarOp.load_var,
            Operand.slot(slot_dst),
            Operand.varRef(var_idx),
            Operand.none,
        );
    }

    /// var:store-var dst var_idx value_op
    ///   set var.root := resolve(value_op); var.bound := true;
    ///   slot[dst] := Var-object. Step #6b.
    pub fn varStoreVar(slot_dst: u12, var_idx: u12, value: Operand) Inst {
        return Inst.primary(
            .var_,
            VarOp.store_var,
            Operand.slot(slot_dst),
            Operand.varRef(var_idx),
            value,
        );
    }

    /// var:var-object dst var_idx  ; slot[dst] := Var-object
    /// (does NOT trap on unbound). Step #6b — Clojure's
    /// `(var x)` / `#'x` reader form lowers to this.
    pub fn varVarObject(slot_dst: u12, var_idx: u12) Inst {
        return Inst.primary(
            .var_,
            VarOp.var_object,
            Operand.slot(slot_dst),
            Operand.varRef(var_idx),
            Operand.none,
        );
    }

    /// coll:list arg_base argc dst  ; slot[dst] := list from
    /// argc consecutive slots starting at arg_base. Step #8c.1.
    pub fn collList(arg_base: u12, argc: u12, dst: u12) Inst {
        return Inst.primary(
            .coll,
            CollOp.list,
            Operand.slot(arg_base),
            .{ .kind = .unused, .index = argc }, // B = raw argc immediate
            Operand.slot(dst),
        );
    }

    /// coll:concat arg_base argc dst  ; slot[dst] := concat of
    /// argc list values starting at arg_base. Step #8c.1.
    pub fn collConcat(arg_base: u12, argc: u12, dst: u12) Inst {
        return Inst.primary(
            .coll,
            CollOp.concat,
            Operand.slot(arg_base),
            .{ .kind = .unused, .index = argc },
            Operand.slot(dst),
        );
    }

    /// ctrl:try-enter catch_pc binding_slot _   ; push handler.
    /// Step #9.1.
    pub fn tryEnter(catch_pc: u12, binding_slot: u12) Inst {
        return Inst.primary(
            .ctrl,
            CtrlOp.try_enter,
            Operand.jump(catch_pc),
            Operand.slot(binding_slot),
            Operand.none,
        );
    }

    /// ctrl:try-enter catch_pc binding_slot finally_pc  ; push
    /// handler with finally. Step #9.2.
    pub fn tryEnterFinally(catch_pc: u12, binding_slot: u12, finally_pc: u12) Inst {
        return Inst.primary(
            .ctrl,
            CtrlOp.try_enter,
            Operand.jump(catch_pc),
            Operand.slot(binding_slot),
            Operand.jump(finally_pc),
        );
    }

    /// ctrl:try-exit post_pc _ _   ; pop handler.
    /// Step #9.1: jump to post_pc.
    /// Step #9.2: if popped handler has finally, push
    /// `.normal(post_pc)` continuation + jump to finally.
    pub fn tryExit(post_pc: u12) Inst {
        return Inst.primary(
            .ctrl,
            CtrlOp.try_exit,
            Operand.jump(post_pc),
            Operand.none,
            Operand.none,
        );
    }

    /// ctrl:finally-exit _ _ _   ; pop FinallyContinuation +
    /// dispatch (.normal jumps post_pc, .throwing continues
    /// unwind). Step #9.2.
    pub fn finallyExit() Inst {
        return Inst.primary(
            .ctrl,
            CtrlOp.finally_exit,
            Operand.none,
            Operand.none,
            Operand.none,
        );
    }

    /// ctrl:throw value_operand _ _   ; throw the resolved value.
    /// Operand kind may be slot, constant, or var. Step #9.1.
    pub fn throwOp(value: Operand) Inst {
        return Inst.primary(
            .ctrl,
            CtrlOp.throw_,
            value,
            Operand.none,
            Operand.none,
        );
    }

    /// coll:vector arg_base argc dst  ; slot[dst] := vector
    /// built from argc consecutive slot values. Step #8c.3.
    pub fn collVector(arg_base: u12, argc: u12, dst: u12) Inst {
        return Inst.primary(
            .coll,
            CollOp.vector,
            Operand.slot(arg_base),
            .{ .kind = .unused, .index = argc },
            Operand.slot(dst),
        );
    }

    /// coll:map arg_base argc dst  ; slot[dst] := persistent map
    /// from argc/2 k,v pairs (argc MUST be even). Phase 3.1.
    pub fn collMap(arg_base: u12, argc: u12, dst: u12) Inst {
        return Inst.primary(
            .coll,
            CollOp.map,
            Operand.slot(arg_base),
            .{ .kind = .unused, .index = argc },
            Operand.slot(dst),
        );
    }

    /// coll:set arg_base argc dst  ; slot[dst] := persistent set
    /// from argc slot values (duplicates collapse). Phase 3.1.
    pub fn collSet(arg_base: u12, argc: u12, dst: u12) Inst {
        return Inst.primary(
            .coll,
            CollOp.set,
            Operand.slot(arg_base),
            .{ .kind = .unused, .index = argc },
            Operand.slot(dst),
        );
    }

    /// jump:jmp target _ _   ; pc := target
    /// `target` is an absolute PC within the current routine.
    pub fn jumpJmp(target_pc: u12) Inst {
        return Inst.primary(
            .jump,
            Jump.jmp,
            Operand.jump(target_pc),
            Operand.none,
            Operand.none,
        );
    }

    /// jump:if-true target test _   ; if truthy(resolve(test)) pc := target
    pub fn jumpIfTrue(target_pc: u12, test_op: Operand) Inst {
        return Inst.primary(
            .jump,
            Jump.if_true,
            Operand.jump(target_pc),
            test_op,
            Operand.none,
        );
    }

    /// jump:if-false target test _  ; if falsy(resolve(test)) pc := target
    pub fn jumpIfFalse(target_pc: u12, test_op: Operand) Inst {
        return Inst.primary(
            .jump,
            Jump.if_false,
            Operand.jump(target_pc),
            test_op,
            Operand.none,
        );
    }

    /// Patch the jump target of an already-emitted jump
    /// instruction. Used by the compiler's back-patching loop
    /// for forward jumps whose target wasn't known at emit time
    /// (peer-AI turn 36 simple-backpatch pattern).
    pub fn patchJumpTarget(inst: *Inst, target_pc: u12) void {
        inst.a = Operand.jump(target_pc);
    }

    /// `closure:make A=prototype_const B=cap_desc_imm C=result_slot`
    /// per VM.md §6 (peer-AI turn 34 descriptor-based shape).
    /// `cap_desc_index` is encoded as a raw-index immediate per
    /// §4.5; the asm helper hides the encoding by using a slot
    /// kind for the operand bits (handler ignores the kind).
    pub fn closureMake(proto_const: u12, cap_desc_index: u12, dst: u12) Inst {
        return Inst.primary(
            .closure,
            Closure_.make,
            Operand.constant(proto_const),
            Operand.slot(cap_desc_index), // raw-index immediate per §4.5
            Operand.slot(dst),
        );
    }

    /// `call:call A=call_base B=argc C=result_slot` per VM.md §6
    /// range-call ABI (peer-AI turn 32). Caller has already
    /// staged closure + args at `slot[A..A+1+argc]`.
    pub fn callCall(call_base: u12, argc: u12, result_slot: u12) Inst {
        return Inst.primary(
            .call,
            Call.call,
            Operand.slot(call_base),
            Operand.slot(argc), // raw-index immediate per §4.5
            Operand.slot(result_slot),
        );
    }

    /// General `mov:move dst, src` where `src` may be any operand
    /// kind that `resolve` accepts (slot / constant / upvalue).
    /// Used by `compileSymbol` for upvalue reads (step 5b):
    /// `moveFrom(dst, Operand.upvalue(u))` lowers a captured-
    /// binding read. The pre-existing `move(dst, slot_src)`
    /// helper remains for the slot-to-slot common case.
    pub fn moveFrom(slot_dst: u12, src: Operand) Inst {
        return Inst.primary(
            .mov,
            Mov.move,
            Operand.slot(slot_dst),
            src,
            Operand.none,
        );
    }

    /// `closure:box-local A=slot` — wrap slot[A]'s current value
    /// into a fresh `UpvalCell`, replacing slot[A] with the cell
    /// pointer. Lazy-boxing emission timing per COMPILER.md §6.1
    /// (peer-AI turn 40).
    pub fn closureBoxLocal(slot_idx: u12) Inst {
        return Inst.primary(
            .closure,
            Closure_.box_local,
            Operand.slot(slot_idx),
            Operand.none,
            Operand.none,
        );
    }

    /// `closure:get-cell A=dst_slot B=cell_slot` — read the
    /// contents of an `UpvalCell` whose pointer lives in slot[B];
    /// write to slot[A]. Same-frame read of a boxed local.
    pub fn closureGetCell(dst: u12, cell_slot: u12) Inst {
        return Inst.primary(
            .closure,
            Closure_.get_cell,
            Operand.slot(dst),
            Operand.slot(cell_slot),
            Operand.none,
        );
    }

    /// `closure:new-cell A=slot` — allocate an uninitialized
    /// UpvalCell, store cell pointer at slot[A]. Step 5c
    /// placeholder cell for letfn* / named fn*.
    pub fn closureNewCell(slot_idx: u12) Inst {
        return Inst.primary(
            .closure,
            Closure_.new_cell,
            Operand.slot(slot_idx),
            Operand.none,
            Operand.none,
        );
    }

    /// `closure:init-cell A=cell_slot B=value_op` — fill
    /// uninitialized cell at slot[A] with resolve(B); set
    /// initialized=true. Step 5c letfn* / named fn* finalize.
    pub fn closureInitCell(cell_slot: u12, value: Operand) Inst {
        return Inst.primary(
            .closure,
            Closure_.init_cell,
            Operand.slot(cell_slot),
            value,
            Operand.none,
        );
    }
};

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

test "Inst size: exactly 64 bits packed" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Inst));
    try testing.expectEqual(@as(usize, 2), @sizeOf(Operand));
}

test "Operand helpers build the right bits" {
    const s = Operand.slot(7);
    try testing.expectEqual(OpKind.slot, s.kind);
    try testing.expectEqual(@as(u12, 7), s.index);

    const c = Operand.constant(42);
    try testing.expectEqual(OpKind.constant, c.kind);
    try testing.expectEqual(@as(u12, 42), c.index);
}

test "VM 5a0: stack and frames structures initialized correctly" {
    // Pins the backing-stack model invariants: after VM.init,
    // `stack.items.len == routine.slot_count`, `frames.items.len == 1`,
    // and frame[0].base_slot == 0.
    const routine = makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 5, "init-shape");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();

    try testing.expectEqual(@as(usize, 5), vm.stack.items.len);
    try testing.expectEqual(@as(usize, 1), vm.frames.items.len);
    try testing.expectEqual(@as(u32, 0), vm.frames.items[0].base_slot);
    try testing.expectEqual(@as(u16, 5), vm.frames.items[0].slot_count);
    try testing.expectEqual(@as(u32, 0), vm.frames.items[0].pc);
    // All slots default-initialized to nil.
    for (vm.stack.items) |s| {
        try testing.expect(s.kind() == .nil);
    }
}

test "VM 5a0: slotPtr through backing stack with base_slot indirection" {
    // Verify that slot access goes through base_slot, not a
    // per-frame slice. With base_slot = 0 (the only case in
    // 5a0), this is functionally equivalent to direct slice
    // access; the test exists to pin the indirection so a
    // future "optimization" that stores a slice can't bypass
    // it silently.
    const consts = [_]Const{cval(value_mod.fromFixnum(42).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0), // s0 = 42
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "slotptr");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();

    // Manually verify slotPtr returns a pointer into vm.stack.items.
    const ptr = try vm.slotPtr(0);
    try testing.expectEqual(&vm.stack.items[0], ptr);

    const result = try vm.run();
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
    // After run, the slot still holds the value (via the same indirection).
    try testing.expectEqual(@as(i64, 42), vm.stack.items[0].asFixnum());
}

test "VM 5a0: slotPtr out-of-range surfaces OperandOutOfRange" {
    const routine = makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 3, "slotptr-oob");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    try testing.expectError(VmError.OperandOutOfRange, vm.slotPtr(3));
    try testing.expectError(VmError.OperandOutOfRange, vm.slotPtr(4095));
}

test "VM: load-nil into slot 0, return slot 0 -> nil" {
    var code = [_]Inst{
        asm_.loadNil(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "load-nil");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .nil);
}

test "VM: load-true into slot 0, return -> true" {
    var code = [_]Inst{
        asm_.loadTrue(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "load-true");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .true_);
}

test "VM: load-false into slot 0, return -> false" {
    var code = [_]Inst{
        asm_.loadFalse(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "load-false");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .false_);
}

test "VM: load-const pulls a fixnum from the pool" {
    const consts = [_]Const{cval(value_mod.fromFixnum(12345).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "load-const");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 12345), result.asFixnum());
}

test "VM: move copies one slot into another" {
    const consts = [_]Const{cval(value_mod.fromFixnum(77).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0), // slot[0] = 77
        asm_.move(1, 0), //      slot[1] = slot[0]
        asm_.returnSlot(1), //   return slot[1]
    };
    const routine = makeRoutine(&code, &consts, 2, "move");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 77), result.asFixnum());
}

test "VM: return_nil halts without reading a slot" {
    var code = [_]Inst{
        asm_.returnNil(),
    };
    const routine = makeRoutine(&code, &.{}, 0, "return-nil");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .nil);
}

test "VM: reading a slot out of range returns OperandOutOfRange" {
    var code = [_]Inst{
        asm_.returnSlot(5), // frame has 1 slot; slot 5 is out of range
    };
    const routine = makeRoutine(&code, &.{}, 1, "oob");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.OperandOutOfRange, res);
}

test "VM: reading a constant out of range returns OperandOutOfRange" {
    var code = [_]Inst{
        asm_.loadConst(0, 9), // pool is empty; const 9 is OOB
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "const-oob");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.OperandOutOfRange, res);
}

// ---- Step #8c.1: coll group tests ---------------------------

test "VM #8c.1: coll:list with argc=0 builds the empty list" {
    var code = [_]Inst{
        asm_.collList(0, 0, 0), // slot[0] := empty list
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "coll-list-empty");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const r = try vm.run();
    try testing.expect(r.kind() == .list);
    try testing.expect(list_mod.isEmpty(r));
}

test "VM #8c.1: coll:list with 3 fixnums builds [1 2 3]" {
    // slot[0] := 1, slot[1] := 2, slot[2] := 3
    // slot[3] := list from slots 0..2
    // return slot[3]
    const c1 = Const{ .value = value_mod.fromFixnum(1).? };
    const c2 = Const{ .value = value_mod.fromFixnum(2).? };
    const c3 = Const{ .value = value_mod.fromFixnum(3).? };
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.loadConst(1, 1),
        asm_.loadConst(2, 2),
        asm_.collList(0, 3, 3),
        asm_.returnSlot(3),
    };
    const routine = makeRoutine(&code, &.{ c1, c2, c3 }, 4, "coll-list-3");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const r = try vm.run();
    try testing.expect(r.kind() == .list);
    try testing.expectEqual(@as(i64, 1), list_mod.head(r).asFixnum());
    try testing.expectEqual(@as(i64, 2), list_mod.head(list_mod.tail(r)).asFixnum());
    try testing.expectEqual(@as(i64, 3), list_mod.head(list_mod.tail(list_mod.tail(r))).asFixnum());
    try testing.expect(list_mod.isEmpty(list_mod.tail(list_mod.tail(list_mod.tail(r)))));
}

test "VM #8c.1: coll:concat with argc=0 builds the empty list" {
    var code = [_]Inst{
        asm_.collConcat(0, 0, 0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "coll-concat-empty");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const r = try vm.run();
    try testing.expect(r.kind() == .list);
    try testing.expect(list_mod.isEmpty(r));
}

test "VM #8c.1: coll:concat ([1 2] [3]) → [1 2 3]" {
    // slot[0] := 1, slot[1] := 2, slot[2] := 3
    // slot[3] := list from slots 0..1   ; [1 2]
    // slot[4] := list from slots 2..2   ; [3]
    // slot[5] := concat from slots 3..4
    // return slot[5]
    const c1 = Const{ .value = value_mod.fromFixnum(1).? };
    const c2 = Const{ .value = value_mod.fromFixnum(2).? };
    const c3 = Const{ .value = value_mod.fromFixnum(3).? };
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.loadConst(1, 1),
        asm_.loadConst(2, 2),
        asm_.collList(0, 2, 3), // [1 2]
        asm_.collList(2, 1, 4), // [3]
        asm_.collConcat(3, 2, 5),
        asm_.returnSlot(5),
    };
    const routine = makeRoutine(&code, &.{ c1, c2, c3 }, 6, "coll-concat");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const r = try vm.run();
    try testing.expect(r.kind() == .list);
    try testing.expectEqual(@as(i64, 1), list_mod.head(r).asFixnum());
    try testing.expectEqual(@as(i64, 2), list_mod.head(list_mod.tail(r)).asFixnum());
    try testing.expectEqual(@as(i64, 3), list_mod.head(list_mod.tail(list_mod.tail(r))).asFixnum());
    try testing.expect(list_mod.isEmpty(list_mod.tail(list_mod.tail(list_mod.tail(r)))));
}

test "VM #8c.1: coll:concat on non-list arg traps KindMismatch" {
    const c1 = Const{ .value = value_mod.fromFixnum(99).? };
    var code = [_]Inst{
        asm_.loadConst(0, 0), // slot[0] := 99 (fixnum, NOT list)
        asm_.collConcat(0, 1, 1),
        asm_.returnSlot(1),
    };
    const routine = makeRoutine(&code, &.{c1}, 2, "coll-concat-kind");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    try testing.expectError(VmError.KindMismatch, vm.run());
}

// ---- Step #9.1: ctrl group tests ---------------------------

test "VM #9.1: try-enter pushes handler, try-exit pops it" {
    // (try 42 (catch any _ 99)) — body returns 42, catch unused.
    // Layout: slot 0 = result; slot 1 = catch binding (unused).
    // Body returns 42 via mov; try-exit jumps past catch; catch
    // would set 99 if reached.
    var code = [_]Inst{
        // PC 0: try-enter catch=4, binding=1, _
        asm_.tryEnter(4, 1),
        // PC 1: body: load 42 into slot 0
        // (We can't loadConst w/o consts; use loadNil and then
        // a constant via consts pool.)
        asm_.loadConst(0, 0),
        // PC 2: try-exit -> jump to post at PC 6
        asm_.tryExit(6),
        // PC 3: jump (just padding; never reached)
        asm_.jumpJmp(6),
        // PC 4: catch entry — set slot 0 to constant index 1 (99)
        asm_.loadConst(0, 1),
        // PC 5: try-exit -> post at PC 6
        asm_.tryExit(6),
        // PC 6: return slot 0
        asm_.returnSlot(0),
    };
    const consts = [_]Const{
        .{ .value = value_mod.fromFixnum(42).? },
        .{ .value = value_mod.fromFixnum(99).? },
    };
    const routine = makeRoutine(&code, &consts, 2, "try-normal");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const r = try vm.run();
    try testing.expectEqual(@as(i64, 42), r.asFixnum());
    // Handler stack empty after normal exit.
    try testing.expectEqual(@as(usize, 0), vm.handlers.items.len);
}

test "VM #9.1: throw caught by current frame's try handler" {
    // (try (throw 7) (catch any e e)) — should return 7.
    var code = [_]Inst{
        // PC 0: try-enter catch=2, binding=1, _
        asm_.tryEnter(2, 1),
        // PC 1: throw constant 0 (= 7)
        asm_.throwOp(Operand{ .kind = .constant, .index = 0 }),
        // PC 2: catch entry — slot 1 was filled by throw with 7;
        // move it to slot 0 (result), then try-exit to PC 4.
        asm_.move(0, 1),
        // PC 3: try-exit -> post at PC 4
        asm_.tryExit(4),
        // PC 4: return slot 0
        asm_.returnSlot(0),
    };
    const consts = [_]Const{
        .{ .value = value_mod.fromFixnum(7).? },
    };
    const routine = makeRoutine(&code, &consts, 2, "try-catch");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const r = try vm.run();
    try testing.expectEqual(@as(i64, 7), r.asFixnum());
    try testing.expectEqual(@as(usize, 0), vm.handlers.items.len);
}

test "VM #9.1: throw with no handler raises UncaughtThrow" {
    // (throw 13) at top level — uncaught.
    var code = [_]Inst{
        asm_.throwOp(Operand{ .kind = .constant, .index = 0 }),
        asm_.returnSlot(0), // unreached
    };
    const consts = [_]Const{
        .{ .value = value_mod.fromFixnum(13).? },
    };
    const routine = makeRoutine(&code, &consts, 1, "uncaught");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    try testing.expectError(VmError.UncaughtThrow, vm.run());
    // Payload stored for diagnostics (step #10 will use this).
    try testing.expect(vm.unhandled_throw != null);
    try testing.expectEqual(@as(i64, 13), vm.unhandled_throw.?.asFixnum());
}

test "VM #9.1: throw inside catch body NOT re-caught by same handler" {
    // (try (throw :a) (catch any e (throw :b)))
    // The inner throw must NOT be caught by the same handler;
    // it should propagate as UncaughtThrow (no outer try here).
    // This is the "classic trap" from peer-AI turn 59 §"Missing
    // trap 1": the throw-handler replaces the try with cleanup
    // so the catch body's own throw bypasses the same handler.
    var code = [_]Inst{
        // PC 0: try-enter catch=2, binding=1, _
        asm_.tryEnter(2, 1),
        // PC 1: throw const 0 = :a (fixnum 1 for simplicity)
        asm_.throwOp(Operand{ .kind = .constant, .index = 0 }),
        // PC 2: catch entry — throw const 1 = :b
        asm_.throwOp(Operand{ .kind = .constant, .index = 1 }),
        // PC 3: try-exit (unreached if inner throw escapes)
        asm_.tryExit(4),
        // PC 4: return
        asm_.returnSlot(0),
    };
    const consts = [_]Const{
        .{ .value = value_mod.fromFixnum(1).? }, // "a"
        .{ .value = value_mod.fromFixnum(2).? }, // "b"
    };
    const routine = makeRoutine(&code, &consts, 2, "catch-rethrow");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    try testing.expectError(VmError.UncaughtThrow, vm.run());
    // Should be the SECOND throw (value 2), not the first.
    try testing.expectEqual(@as(i64, 2), vm.unhandled_throw.?.asFixnum());
}

test "VM: exhausting bytecode without return surfaces BytecodeExhausted" {
    var code = [_]Inst{
        asm_.loadNil(0),
        // no return — fall off the end
    };
    const routine = makeRoutine(&code, &.{}, 1, "fallthrough");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.BytecodeExhausted, res);
}

test "VM: known-but-not-implemented group returns UnimplementedOpcode" {
    // transient group (8) with variant 0 — known group, not wired yet.
    //
    // **Placeholder rotation discipline** (peer-AI turn 37): when a
    // new group lands, this placeholder rotates to the NEXT
    // still-unwired group. History: math → jump → closure → var_
    // → coll → transient. Next likely: transient → hash → etc.
    // Use `runWithFuel` (not `run`) so an accidental rotation bug
    // trips fuel exhaustion instead of hanging the suite (22-min
    // hang in step #3 — don't repeat).
    const var_op = Inst.primary(
        .transient,
        @as(Mov, @enumFromInt(0)), // variant 0 — placeholder; only the group matters
        Operand.slot(0),
        Operand.slot(0),
        Operand.slot(0),
    );
    var code = [_]Inst{
        var_op,
        asm_.returnNil(),
    };
    const routine = makeRoutine(&code, &.{}, 1, "unimpl");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.runWithFuel(100);
    try testing.expectError(VmError.UnimplementedOpcode, res);
}

test "VM: unrecognized group (bit-pattern 60) returns BytecodeCorruption" {
    // Build a raw Inst with a group number outside v1's allocated
    // space (60, well above the 14 v1 groups). The non-exhaustive
    // `Group` enum lets us emit this without aborting; dispatch
    // should detect and surface BytecodeCorruption.
    const raw: Inst = .{
        .kind = .primary,
        .group = 60,
        .variant = 0,
        .a = Operand.none,
        .b = Operand.none,
        .c = Operand.none,
    };
    var code = [_]Inst{ raw, asm_.returnNil() };
    const routine = makeRoutine(&code, &.{}, 1, "corrupt");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.BytecodeCorruption, res);
}

test "VM: resolve on .unused operand returns InvalidOperandKind" {
    // mov:move with source operand B = unused. Handler calls
    // resolve(inst.b), which should surface InvalidOperandKind
    // rather than the ambiguous OperandOutOfRange.
    const bad_move: Inst = .{
        .kind = .primary,
        .group = @intFromEnum(Group.mov),
        .variant = @intFromEnum(Mov.move),
        .a = Operand.slot(0),
        .b = Operand.none, // .unused
        .c = Operand.none,
    };
    var code = [_]Inst{ bad_move, asm_.returnNil() };
    const routine = makeRoutine(&code, &.{}, 1, "unused-operand");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

test "VM math:add: constant + constant = fixnum sum" {
    // The exact bytecode the tiny step-#2 compiler emits for `(+ 1 2)`:
    //   math:add  s0, c0, c1     ; s0 = 1 + 2
    //   call:return s0
    const consts = [_]Const{
        cval(value_mod.fromFixnum(1).?),
        cval(value_mod.fromFixnum(2).?),
    };
    var code = [_]Inst{
        asm_.mathAdd(0, Operand.constant(0), Operand.constant(1)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "(+ 1 2)");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "VM math:add: slot + slot through prelude staging" {
    // Demonstrates the path the eventual real compiler takes
    // when args have non-trivial sub-expressions: load each into
    // a slot first, then add.
    const consts = [_]Const{
        cval(value_mod.fromFixnum(10).?),
        cval(value_mod.fromFixnum(32).?),
    };
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.loadConst(1, 1),
        asm_.mathAdd(2, Operand.slot(0), Operand.slot(1)),
        asm_.returnSlot(2),
    };
    const routine = makeRoutine(&code, &consts, 3, "(+ 10 32)");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "VM math:add: negative + negative" {
    const consts = [_]Const{
        cval(value_mod.fromFixnum(-7).?),
        cval(value_mod.fromFixnum(-5).?),
    };
    var code = [_]Inst{
        asm_.mathAdd(0, Operand.constant(0), Operand.constant(1)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "(+ -7 -5)");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, -12), result.asFixnum());
}

test "VM math:add: i48-range sum wraps to IntegerOverflow" {
    // fixnum_max + 1 overflows i48 and (until bignum Scope B
    // lands) traps as IntegerOverflow rather than silently
    // wrapping or losing precision.
    const consts = [_]Const{
        cval(value_mod.fromFixnum(value_mod.fixnum_max).?),
        cval(value_mod.fromFixnum(1).?),
    };
    var code = [_]Inst{
        asm_.mathAdd(0, Operand.constant(0), Operand.constant(1)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "(+ fixnum_max 1)");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.IntegerOverflow, res);
}

test "VM math:add: non-fixnum operand surfaces KindMismatch" {
    // float + fixnum is supported eventually (cross-type
    // promotion); for step #2 we surface VM.md §13's existing
    // `:kind-mismatch` rather than introducing a parallel
    // taxonomy (peer-AI turn 33).
    const consts = [_]Const{
        cval(value_mod.fromFloat(1.5)),
        cval(value_mod.fromFixnum(2).?),
    };
    var code = [_]Inst{
        asm_.mathAdd(0, Operand.constant(0), Operand.constant(1)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "(+ 1.5 2)");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.KindMismatch, res);
}

test "VM math:add: i48-range underflow traps as IntegerOverflow" {
    // The negative-side mirror of the positive overflow test
    // above (peer-AI turn 33: positive-only coverage missed
    // half the implementation).
    const consts = [_]Const{
        cval(value_mod.fromFixnum(value_mod.fixnum_min).?),
        cval(value_mod.fromFixnum(-1).?),
    };
    var code = [_]Inst{
        asm_.mathAdd(0, Operand.constant(0), Operand.constant(1)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "(+ fixnum_min -1)");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.IntegerOverflow, res);
}

test "VM math:add: dst/src aliasing is well-defined (math:add s0, s0, c0)" {
    // The handler must resolve BOTH source operands BEFORE
    // writing the destination. Otherwise an aliased dst+lhs
    // (or dst+rhs) would silently produce wrong results once
    // future codegen reuses slots (peer-AI turn 33).
    const consts = [_]Const{
        cval(value_mod.fromFixnum(1).?),
        cval(value_mod.fromFixnum(40).?),
    };
    var code = [_]Inst{
        asm_.loadConst(0, 0), //                      s0 = 1
        asm_.mathAdd(0, Operand.slot(0), Operand.constant(1)), // s0 = s0 + 40
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "alias-lhs");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 41), result.asFixnum());
}

test "VM math:add: dst/rhs aliasing (math:add s0, c0, s0)" {
    const consts = [_]Const{
        cval(value_mod.fromFixnum(40).?),
        cval(value_mod.fromFixnum(1).?),
    };
    var code = [_]Inst{
        asm_.loadConst(0, 1), //                      s0 = 1
        asm_.mathAdd(0, Operand.constant(0), Operand.slot(0)), // s0 = 40 + s0
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "alias-rhs");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 41), result.asFixnum());
}

test "VM math:add: mixed slot+constant operand kinds" {
    // Pins resolve() behavior across kind combinations the
    // codegen will actually emit (peer-AI turn 33).
    const consts = [_]Const{cval(value_mod.fromFixnum(100).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0), //                       s0 = 100
        asm_.mathAdd(1, Operand.slot(0), Operand.constant(0)), // slot+const
        asm_.mathAdd(2, Operand.constant(0), Operand.slot(1)), // const+slot
        asm_.returnSlot(2),
    };
    const routine = makeRoutine(&code, &consts, 3, "mixed");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 300), result.asFixnum());
}

// ---- step 5d0: cmp:lt tests ----

test "VM cmp:lt: true case (1 < 2)" {
    const consts = [_]Const{
        cval(value_mod.fromFixnum(1).?),
        cval(value_mod.fromFixnum(2).?),
    };
    var code = [_]Inst{
        asm_.cmpLt(0, Operand.constant(0), Operand.constant(1)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "lt-true");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.isBool());
    try testing.expectEqual(true, result.asBool());
}

test "VM cmp:lt: false case (2 < 1)" {
    const consts = [_]Const{
        cval(value_mod.fromFixnum(2).?),
        cval(value_mod.fromFixnum(1).?),
    };
    var code = [_]Inst{
        asm_.cmpLt(0, Operand.constant(0), Operand.constant(1)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "lt-false");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.isBool());
    try testing.expectEqual(false, result.asBool());
}

test "VM cmp:lt: equal case (2 < 2) — strict less-than yields false" {
    const consts = [_]Const{cval(value_mod.fromFixnum(2).?)};
    var code = [_]Inst{
        asm_.cmpLt(0, Operand.constant(0), Operand.constant(0)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "lt-eq");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(false, result.asBool());
}

test "VM cmp:lt: negative + positive (-5 < 3)" {
    const consts = [_]Const{
        cval(value_mod.fromFixnum(-5).?),
        cval(value_mod.fromFixnum(3).?),
    };
    var code = [_]Inst{
        asm_.cmpLt(0, Operand.constant(0), Operand.constant(1)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "lt-neg");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(true, result.asBool());
}

test "VM cmp:lt: non-fixnum operand traps :kind-mismatch" {
    // True (bool, kind=.bool_) is not a fixnum.
    var code = [_]Inst{
        asm_.loadTrue(0),
        asm_.loadConst(1, 0),
        asm_.cmpLt(2, Operand.slot(0), Operand.slot(1)),
        asm_.returnSlot(2),
    };
    const consts = [_]Const{cval(value_mod.fromFixnum(1).?)};
    const routine = makeRoutine(&code, &consts, 3, "lt-kind");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.KindMismatch, res);
}

test "VM cmp:lt: writing to a constant operand surfaces InvalidOperandKind" {
    const consts = [_]Const{cval(value_mod.fromFixnum(1).?)};
    var code = [_]Inst{
        Inst.primary(
            .cmp,
            Cmp.lt,
            Operand.constant(0), // dst can't be a constant
            Operand.constant(0),
            Operand.constant(0),
        ),
        asm_.returnNil(),
    };
    const routine = makeRoutine(&code, &consts, 1, "lt-bad-dst");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

test "VM cmp:lt: unimplemented variant (lte) returns UnimplementedOpcode" {
    var code = [_]Inst{
        Inst.primary(.cmp, Cmp.lte, Operand.slot(0), Operand.slot(0), Operand.slot(0)),
        asm_.returnNil(),
    };
    const routine = makeRoutine(&code, &.{}, 1, "lt-lte");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.UnimplementedOpcode, res);
}

// ---- step #6a: Var + Namespace + var:load-var tests ----

test "VM #6a: Namespace.intern creates an unbound Var, lookup returns it" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "init"));
    defer vm.deinit();
    const ns = vm.ensureNamespace();
    const v1 = try ns.intern("x");
    try testing.expect(!v1.bound);
    try testing.expect(v1.root.isNil());
    // Re-intern returns the SAME Var (identity stable).
    const v2 = try ns.intern("x");
    try testing.expectEqual(v1, v2);
    // Lookup of unknown returns null.
    try testing.expect(ns.lookup("y") == null);
}

test "VM #6a: var:load-var returns var.root for bound var" {
    var vm = try VM.init(
        testing.allocator,
        &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "stub"),
    );
    defer vm.deinit();

    // Intern + bind x = 42 in the VM's namespace.
    const ns = vm.ensureNamespace();
    const x = try ns.intern("x");
    x.root = value_mod.fromFixnum(42).?;
    x.bound = true;

    // Build a routine that references x via var_table[0] and
    // patch the VM's top frame to use it. Direct manipulation —
    // tests-only API; the compiler will set this up properly
    // in step #6c.
    const var_table = [_]*Var{x};
    var code = [_]Inst{
        asm_.varLoadVar(0, 0),
        asm_.returnSlot(0),
    };
    const routine = Routine{
        .code = &code,
        .consts = &.{},
        .slot_count = 1,
        .var_table = &var_table,
    };
    // Reset the VM's frame to the new routine. (Hacky but
    // matches what we did before compileTiny existed for the
    // earlier VM tests.)
    vm.frames.items[0].routine = &routine;
    vm.frames.items[0].pc = 0;
    vm.frames.items[0].slot_count = routine.slot_count;
    // Stack already has 1 slot from the stub routine.
    const result = try vm.run();
    try testing.expect(result.isFixnum());
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "VM #6a: var:load-var on unbound Var traps :unbound-var" {
    var vm = try VM.init(
        testing.allocator,
        &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "stub"),
    );
    defer vm.deinit();

    const ns = vm.ensureNamespace();
    const x = try ns.intern("undefined-yet"); // never bound

    const var_table = [_]*Var{x};
    var code = [_]Inst{
        asm_.varLoadVar(0, 0),
        asm_.returnSlot(0),
    };
    const routine = Routine{
        .code = &code,
        .consts = &.{},
        .slot_count = 1,
        .var_table = &var_table,
    };
    vm.frames.items[0].routine = &routine;
    vm.frames.items[0].pc = 0;
    vm.frames.items[0].slot_count = routine.slot_count;
    const res = vm.run();
    try testing.expectError(VmError.UnboundVar, res);
}

test "VM #6a: var:load-var operand index out of range traps :operand-out-of-range" {
    var vm = try VM.init(
        testing.allocator,
        &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "stub"),
    );
    defer vm.deinit();

    // Empty var_table, but instruction references index 5.
    var code = [_]Inst{
        asm_.varLoadVar(0, 5),
        asm_.returnSlot(0),
    };
    const routine = Routine{
        .code = &code,
        .consts = &.{},
        .slot_count = 1,
        // var_table = default empty
    };
    vm.frames.items[0].routine = &routine;
    vm.frames.items[0].pc = 0;
    vm.frames.items[0].slot_count = routine.slot_count;
    const res = vm.run();
    try testing.expectError(VmError.OperandOutOfRange, res);
}

test "VM #6a: var:load-var with non-V B operand traps :invalid-operand-kind" {
    var vm = try VM.init(
        testing.allocator,
        &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "stub"),
    );
    defer vm.deinit();

    // Hand-build a malformed var:load-var with B as a slot
    // operand instead of a var operand.
    var code = [_]Inst{
        Inst.primary(
            .var_,
            VarOp.load_var,
            Operand.slot(0),
            Operand.slot(0), // B should be var(idx); slot is invalid
            Operand.none,
        ),
        asm_.returnNil(),
    };
    const routine = Routine{
        .code = &code,
        .consts = &.{},
        .slot_count = 1,
    };
    vm.frames.items[0].routine = &routine;
    vm.frames.items[0].pc = 0;
    vm.frames.items[0].slot_count = routine.slot_count;
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

// ---- step #6b: var:store-var + var:var-object tests ----

test "VM #6b: var:store-var sets root, marks bound, returns Var object" {
    var vm = try VM.init(
        testing.allocator,
        &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "stub"),
    );
    defer vm.deinit();

    const ns = vm.ensureNamespace();
    const x = try ns.intern("x");
    try testing.expect(!x.bound);

    const var_table = [_]*Var{x};
    const consts = [_]Const{cval(value_mod.fromFixnum(42).?)};
    var code = [_]Inst{
        asm_.varStoreVar(0, 0, Operand.constant(0)), // x = 42; slot[0] = #'x
        asm_.returnSlot(0),
    };
    const routine = Routine{
        .code = &code,
        .consts = &consts,
        .slot_count = 1,
        .var_table = &var_table,
    };
    vm.frames.items[0].routine = &routine;
    vm.frames.items[0].pc = 0;
    vm.frames.items[0].slot_count = routine.slot_count;

    const result = try vm.run();
    // store-var returns the Var object, not the value.
    try testing.expect(result.kind() == .var_);
    try testing.expectEqual(x, VM.asVar(result));
    // Var state is now bound to 42.
    try testing.expect(x.bound);
    try testing.expectEqual(@as(i64, 42), x.root.asFixnum());
}

test "VM #6b: var:store-var twice preserves Var identity (rebind in place)" {
    var vm = try VM.init(
        testing.allocator,
        &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "stub"),
    );
    defer vm.deinit();

    const ns = vm.ensureNamespace();
    const x = try ns.intern("x");

    const var_table = [_]*Var{x};
    const consts = [_]Const{
        cval(value_mod.fromFixnum(5).?),
        cval(value_mod.fromFixnum(10).?),
    };
    // Bind x=5, then x=10, then return the result of the second
    // store-var. Same Var; root updated.
    var code = [_]Inst{
        asm_.varStoreVar(0, 0, Operand.constant(0)), // x = 5
        asm_.varStoreVar(0, 0, Operand.constant(1)), // x = 10
        asm_.returnSlot(0),
    };
    const routine = Routine{
        .code = &code,
        .consts = &consts,
        .slot_count = 1,
        .var_table = &var_table,
    };
    vm.frames.items[0].routine = &routine;
    vm.frames.items[0].pc = 0;
    vm.frames.items[0].slot_count = routine.slot_count;

    const result = try vm.run();
    try testing.expect(result.kind() == .var_);
    try testing.expectEqual(x, VM.asVar(result));
    try testing.expectEqual(@as(i64, 10), x.root.asFixnum());
}

test "VM #6b: var:var-object returns the Var WITHOUT trapping on unbound" {
    var vm = try VM.init(
        testing.allocator,
        &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "stub"),
    );
    defer vm.deinit();

    const ns = vm.ensureNamespace();
    const x = try ns.intern("never-bound");
    try testing.expect(!x.bound);

    const var_table = [_]*Var{x};
    var code = [_]Inst{
        asm_.varVarObject(0, 0),
        asm_.returnSlot(0),
    };
    const routine = Routine{
        .code = &code,
        .consts = &.{},
        .slot_count = 1,
        .var_table = &var_table,
    };
    vm.frames.items[0].routine = &routine;
    vm.frames.items[0].pc = 0;
    vm.frames.items[0].slot_count = routine.slot_count;

    const result = try vm.run();
    try testing.expect(result.kind() == .var_);
    try testing.expectEqual(x, VM.asVar(result));
    try testing.expect(!x.bound); // var-object did NOT bind it
}

test "VM jump:jmp skips past an instruction" {
    // mov:load-const s0, c0          ; s0 = 1
    // jump:jmp 3                     ; skip past the next instruction
    // mov:load-const s0, c1          ; (skipped) would set s0 = 99
    // call:return s0                 ; return s0 = 1
    const consts = [_]Const{
        cval(value_mod.fromFixnum(1).?),
        cval(value_mod.fromFixnum(99).?),
    };
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.jumpJmp(3),
        asm_.loadConst(0, 1),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "jmp");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "VM jump:if-false branches when test is nil" {
    // s0 = 99
    // jump:if-false 3, s0   ; s0 is fixnum (truthy) → don't branch (FAILS the test)
    // ... this isn't right. Need to load nil into s0 first.
    var code = [_]Inst{
        asm_.loadNil(0),
        asm_.jumpIfFalse(3, Operand.slot(0)), // s0 is nil (falsy) → branch to pc=3
        asm_.returnNil(), //                    (skipped)
        asm_.loadTrue(0), //                    (jumped here)
        asm_.returnSlot(0), //                  return true
    };
    const routine = makeRoutine(&code, &.{}, 1, "if-false-nil");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .true_);
}

test "VM jump:if-false branches when test is false" {
    var code = [_]Inst{
        asm_.loadFalse(0),
        asm_.jumpIfFalse(3, Operand.slot(0)),
        asm_.returnNil(),
        asm_.loadTrue(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "if-false-bool");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .true_);
}

test "VM jump:if-false does NOT branch when test is true" {
    var code = [_]Inst{
        asm_.loadTrue(0),
        asm_.jumpIfFalse(3, Operand.slot(0)),
        asm_.returnSlot(0), //                  fall through; return true
        asm_.loadNil(0), //                     (not reached)
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "if-false-truthy");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .true_);
}

test "VM jump:if-false does NOT branch when test is fixnum 0 (truthy)" {
    // PLAN §6.2 surprise: 0 is TRUTHY in nexis.
    const consts = [_]Const{cval(value_mod.fromFixnum(0).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0), //                s0 = 0
        asm_.jumpIfFalse(3, Operand.slot(0)), // 0 is truthy → don't branch
        asm_.returnSlot(0), //                  fall through; return 0
        asm_.loadNil(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "if-false-zero");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 0), result.asFixnum());
}

test "VM jump:if-true branches when test is true" {
    var code = [_]Inst{
        asm_.loadTrue(0),
        asm_.jumpIfTrue(3, Operand.slot(0)),
        asm_.returnNil(), //                    (skipped)
        asm_.loadFalse(0), //                   (jumped here)
        asm_.returnSlot(0), //                  return false
    };
    const routine = makeRoutine(&code, &.{}, 1, "if-true-true");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .false_);
}

test "VM jump:if-true does NOT branch when test is nil" {
    var code = [_]Inst{
        asm_.loadNil(0),
        asm_.jumpIfTrue(3, Operand.slot(0)),
        asm_.returnSlot(0), //                  fall through; return nil
        asm_.loadTrue(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "if-true-nil");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .nil);
}

test "VM jump: target out of routine code range surfaces OperandOutOfRange" {
    // Routine has 2 instructions (indices 0-1); jumping to 5 is invalid.
    var code = [_]Inst{
        asm_.jumpJmp(5),
        asm_.returnNil(),
    };
    const routine = makeRoutine(&code, &.{}, 1, "bad-jump");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.OperandOutOfRange, res);
}

test "VM jump: patchJumpTarget rewrites operand A in place" {
    // Verify the asm_ helper used by the compiler back-patches
    // correctly: emit a placeholder jump, then patch it.
    var inst = asm_.jumpJmp(0); // placeholder target
    asm_.patchJumpTarget(&inst, 7);
    try testing.expectEqual(OpKind.jump, inst.a.kind);
    try testing.expectEqual(@as(u12, 7), inst.a.index);
}

test "VM jump: target with wrong operand kind surfaces InvalidOperandKind" {
    // Hand-build jump:jmp with target encoded as slot(0) instead
    // of jump(0). Without the kind check this would loop forever
    // (peer-AI turn 37: this is the bug that almost shipped in
    // step #3). With the kind check it surfaces a clean error.
    const bad_jump: Inst = .{
        .kind = .primary,
        .group = @intFromEnum(Group.jump),
        .variant = @intFromEnum(Jump.jmp),
        .a = Operand.slot(0), // wrong kind for jump target
        .b = Operand.none,
        .c = Operand.none,
    };
    var code = [_]Inst{ bad_jump, asm_.returnNil() };
    const routine = makeRoutine(&code, &.{}, 1, "bad-jump-kind");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    // Bounded execution as a defense-in-depth measure: even if the
    // kind check were removed, this can't hang the suite.
    const res = vm.runWithFuel(100);
    try testing.expectError(VmError.InvalidOperandKind, res);
}

test "VM jump: target == code.len traps OperandOutOfRange" {
    // Code has 2 instructions (indices 0-1); jumping to index 2
    // would surface BytecodeExhausted on the next dispatch.
    // applyJump catches this eagerly as OperandOutOfRange so
    // the error kind matches the cause.
    var code = [_]Inst{
        asm_.jumpJmp(2), // target == code.len → invalid
        asm_.returnNil(),
    };
    const routine = makeRoutine(&code, &.{}, 1, "jump-at-end");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.runWithFuel(100);
    try testing.expectError(VmError.OperandOutOfRange, res);
}

test "VM jump:if-false: constant operand as test resolves correctly" {
    // Conditional test operand can be any kind resolve() handles.
    // Constant pool entry → branch / fall through per its truthiness.
    const consts = [_]Const{cval(value_mod.fromBool(false))};
    var code = [_]Inst{
        asm_.jumpIfFalse(3, Operand.constant(0)), // c0=false → branch
        asm_.returnNil(), // (skipped)
        asm_.returnNil(), // (skipped)
        asm_.loadTrue(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "if-false-const");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .true_);
}

test "VM jump:if-true: non-taken branch falls through with pc pre-increment" {
    // Pins the dispatch invariant: pc is incremented BEFORE
    // handler execution, so non-taken conditionals "fall through"
    // by leaving frame.pc alone. If pc were post-incremented,
    // this test would loop on the jump instruction.
    var code = [_]Inst{
        asm_.loadFalse(0),
        asm_.jumpIfTrue(0, Operand.slot(0)), // false → don't branch; pc=2 next
        asm_.returnSlot(0), // halt with false
    };
    const routine = makeRoutine(&code, &.{}, 1, "fallthrough");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .false_);
}

test "VM math:add: writing to a constant operand surfaces InvalidOperandKind" {
    // Hand-build an instruction with destination kind = constant.
    // Sources are valid (resolve to fixnums from the pool), so
    // the addition succeeds and the failure surfaces at the
    // destination store. Per VM.md §13's `:invalid-operand-kind`
    // row, write-to-constant is an invalid operand kind in the
    // store context, NOT "known but not yet wired" — peer-AI
    // turn 35 holistic-review correction.
    const consts = [_]Const{
        cval(value_mod.fromFixnum(1).?),
        cval(value_mod.fromFixnum(2).?),
    };
    const bad: Inst = .{
        .kind = .primary,
        .group = @intFromEnum(Group.math),
        .variant = @intFromEnum(Math.add),
        .a = Operand.constant(0), // illegal destination kind
        .b = Operand.constant(0),
        .c = Operand.constant(1),
    };
    var code = [_]Inst{ bad, asm_.returnNil() };
    const routine = makeRoutine(&code, &consts, 1, "bad-dst");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

// ---- step 5a1: closure + call tests (peer-AI turn 42 checklist) ----

test "VM 5a1: closure:make produces a function-kind Value" {
    // Hand-assemble: child routine returns nil. Parent routine
    // makes a closure for it, returns the closure.
    var child_code = [_]Inst{asm_.returnNil()};
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .capture_descs = &.{},
        .slot_count = 1,
        .fixed_arity = 0,
        .upvalue_count = 0,
        .name = "child",
    };
    const parent_consts = [_]Const{croutine(&child_routine)};
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var parent_code = [_]Inst{
        asm_.closureMake(0, 0, 0), // closure:make c0(routine), cap_desc 0 (empty), s0
        asm_.returnSlot(0),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 1,
        .fixed_arity = 0,
        .upvalue_count = 0,
        .name = "parent",
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .function);
    const c = VM.asClosure(result);
    try testing.expectEqual(&child_routine, c.routine);
    try testing.expectEqual(@as(usize, 0), c.upvalues.len);
}

test "VM 5a1: ((fn* [] 42)) — no-arg closure call returns its body value" {
    // Child: load 42 into s0, return.
    const child_consts = [_]Const{cval(value_mod.fromFixnum(42).?)};
    var child_code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.returnSlot(0),
    };
    const child_routine = Routine{
        .code = &child_code,
        .consts = &child_consts,
        .slot_count = 1,
    };
    // Parent: closure:make → s0; call:call s0,0,s0; call:return s0.
    // call_base = 0 (the closure slot); argc = 0; result_slot = 0.
    // Note dst slot reuses s0 — the closure value is consumed by
    // the call, then overwritten by the result. Legal per VM.md §6.
    const parent_consts = [_]Const{croutine(&child_routine)};
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var parent_code = [_]Inst{
        asm_.closureMake(0, 0, 0),
        asm_.callCall(0, 0, 0),
        asm_.returnSlot(0),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 1,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "VM 5a1: ((fn* [x] (+ x 1)) 5) = 6 — single arg" {
    // Child: math:add s1, s0, c0 (s0 = param x); return s1.
    const child_consts = [_]Const{cval(value_mod.fromFixnum(1).?)};
    var child_code = [_]Inst{
        asm_.mathAdd(1, Operand.slot(0), Operand.constant(0)),
        asm_.returnSlot(1),
    };
    const child_routine = Routine{
        .code = &child_code,
        .consts = &child_consts,
        .slot_count = 2,
        .fixed_arity = 1,
    };
    // Parent: load fn into s0, load 5 into s1, call_base=s0 argc=1
    // result=s2; return s2. slot_count = 3.
    const parent_consts = [_]Const{
        croutine(&child_routine),
        cval(value_mod.fromFixnum(5).?),
    };
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var parent_code = [_]Inst{
        asm_.closureMake(0, 0, 0), // s0 = closure
        asm_.loadConst(1, 1), //         s1 = 5 (the arg)
        asm_.callCall(0, 1, 2), //       s2 = (closure 5)
        asm_.returnSlot(2),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 3,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 6), result.asFixnum());
}

test "VM 5a1: ((fn* [x y] (+ x y)) 3 4) = 7 — two-arg call" {
    // Child: math:add s2, s0, s1; return s2. slot_count=3, arity=2.
    var child_code = [_]Inst{
        asm_.mathAdd(2, Operand.slot(0), Operand.slot(1)),
        asm_.returnSlot(2),
    };
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 3,
        .fixed_arity = 2,
    };
    const parent_consts = [_]Const{
        croutine(&child_routine),
        cval(value_mod.fromFixnum(3).?),
        cval(value_mod.fromFixnum(4).?),
    };
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var parent_code = [_]Inst{
        asm_.closureMake(0, 0, 0), // s0 = closure
        asm_.loadConst(1, 1), //         s1 = 3
        asm_.loadConst(2, 2), //         s2 = 4
        asm_.callCall(0, 2, 3), //       s3 = (closure 3 4)
        asm_.returnSlot(3),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 4,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

test "VM 5a1: arity mismatch — too few args traps :arity-mismatch" {
    // Child expects 2 args; we pass 1.
    var child_code = [_]Inst{asm_.returnNil()};
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 2,
        .fixed_arity = 2,
    };
    const parent_consts = [_]Const{
        croutine(&child_routine),
        cval(value_mod.fromFixnum(1).?),
    };
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var parent_code = [_]Inst{
        asm_.closureMake(0, 0, 0),
        asm_.loadConst(1, 1),
        asm_.callCall(0, 1, 2), // argc=1 but child expects 2
        asm_.returnSlot(2),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 3,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.ArityMismatch, res);
}

test "VM 5a1: arity mismatch — too many args traps :arity-mismatch" {
    var child_code = [_]Inst{asm_.returnNil()};
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 1,
        .fixed_arity = 1,
    };
    const parent_consts = [_]Const{
        croutine(&child_routine),
        cval(value_mod.fromFixnum(1).?),
        cval(value_mod.fromFixnum(2).?),
    };
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var parent_code = [_]Inst{
        asm_.closureMake(0, 0, 0),
        asm_.loadConst(1, 1),
        asm_.loadConst(2, 2),
        asm_.callCall(0, 2, 3), // argc=2 but child expects 1
        asm_.returnSlot(3),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 4,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.ArityMismatch, res);
}

test "VM 5a1: not-callable — call:call on a fixnum traps :not-callable" {
    const consts = [_]Const{cval(value_mod.fromFixnum(42).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0), // s0 = 42 (not a closure)
        asm_.callCall(0, 0, 1),
        asm_.returnSlot(1),
    };
    const routine = Routine{
        .code = &code,
        .consts = &consts,
        .slot_count = 2,
    };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.NotCallable, res);
}

test "VM 5a1: mov:load-const with routine-typed Const traps :invalid-operand-kind" {
    // Pins the typed-Const-pool enforcement: mov:load-const cannot
    // load a Const.routine into a slot.
    var dummy_code = [_]Inst{asm_.returnNil()};
    const dummy_routine = Routine{ .code = &dummy_code, .consts = &.{}, .slot_count = 1 };
    const consts = [_]Const{croutine(&dummy_routine)};
    var code = [_]Inst{
        asm_.loadConst(0, 0), // tries to load a routine into a slot
        asm_.returnSlot(0),
    };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 1 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

test "VM 5a1: closure:make with value-typed Const traps :invalid-operand-kind" {
    // Symmetric: closure:make cannot use a Const.value as its
    // prototype operand.
    const consts = [_]Const{cval(value_mod.fromFixnum(1).?)};
    const caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var code = [_]Inst{
        asm_.closureMake(0, 0, 0), // c0 is a value, not a routine
        asm_.returnSlot(0),
    };
    const routine = Routine{
        .code = &code,
        .consts = &consts,
        .capture_descs = &caps,
        .slot_count = 1,
    };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

test "VM 5a1: closure:make capture descriptor source-count mismatch traps" {
    // Child expects 1 upvalue; descriptor has 0 sources.
    var child_code = [_]Inst{asm_.returnNil()};
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 1,
        .fixed_arity = 0,
        .upvalue_count = 1, // mismatch with descriptor below
    };
    const parent_consts = [_]Const{croutine(&child_routine)};
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }}; // 0 sources
    var parent_code = [_]Inst{
        asm_.closureMake(0, 0, 0),
        asm_.returnSlot(0),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 1,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.CaptureCountMismatch, res);
}

test "VM 5a1: callee local slots are nil-initialized even when stack overlaps caller high slots" {
    // Child has slot_count=3 (slot 0 = arg, slots 1-2 are locals).
    // Body returns slot 2 without writing it — should be nil.
    var child_code = [_]Inst{asm_.returnSlot(2)};
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 3,
        .fixed_arity = 1,
    };
    // Parent: stuff non-nil into all of its high slots first to
    // create the "overlap with caller's stale data" scenario.
    const parent_consts = [_]Const{
        croutine(&child_routine),
        cval(value_mod.fromFixnum(7).?),
        cval(value_mod.fromFixnum(99).?), // poison value to detect leak
    };
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var parent_code = [_]Inst{
        // Pre-poison high slots that will OVERLAP with callee locals.
        asm_.loadConst(2, 2), // s2 = 99
        asm_.loadConst(3, 2), // s3 = 99
        asm_.closureMake(0, 0, 0), // s0 = closure
        asm_.loadConst(1, 1), //         s1 = 7 (the arg)
        asm_.callCall(0, 1, 4), //       call_base=0, argc=1, result→s4
        asm_.returnSlot(4),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 5,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const result = try vm.run();
    // If the callee's slot 2 had leaked the parent's poisoned 99,
    // we'd get a fixnum back. Nil-init means we get nil.
    try testing.expect(result.kind() == .nil);
}

test "VM 5a1: call:call with constant operand as A traps :invalid-operand-kind" {
    // call:call requires A=slot (the call_base). A=constant is
    // invalid (peer-AI turn 43 catch).
    var dummy_code = [_]Inst{asm_.returnNil()};
    const dummy_routine = Routine{ .code = &dummy_code, .consts = &.{}, .slot_count = 1 };
    const consts = [_]Const{croutine(&dummy_routine)};
    const bad_call: Inst = .{
        .kind = .primary,
        .group = @intFromEnum(Group.call),
        .variant = @intFromEnum(Call.call),
        .a = Operand.constant(0), // illegal: must be slot
        .b = Operand.slot(0),
        .c = Operand.slot(0),
    };
    var code = [_]Inst{ bad_call, asm_.returnNil() };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 1 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

test "VM 5a1: call:call with constant operand as C traps :invalid-operand-kind" {
    // call:call requires C=slot (the result). C=constant is invalid.
    var child_code = [_]Inst{asm_.returnNil()};
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 1,
        .fixed_arity = 0,
    };
    const consts = [_]Const{croutine(&child_routine)};
    const caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    const bad_call: Inst = .{
        .kind = .primary,
        .group = @intFromEnum(Group.call),
        .variant = @intFromEnum(Call.call),
        .a = Operand.slot(0),
        .b = Operand.slot(0),
        .c = Operand.constant(0), // illegal: must be slot
    };
    var code = [_]Inst{
        asm_.closureMake(0, 0, 0),
        bad_call,
        asm_.returnNil(),
    };
    const routine = Routine{
        .code = &code,
        .consts = &consts,
        .capture_descs = &caps,
        .slot_count = 1,
    };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

test "VM 5a1: closure:make with capture descriptor index out of range traps OperandOutOfRange" {
    var child_code = [_]Inst{asm_.returnNil()};
    const child_routine = Routine{ .code = &child_code, .consts = &.{}, .slot_count = 1 };
    const consts = [_]Const{croutine(&child_routine)};
    // No capture descriptors at all — index 0 is OOR.
    var code = [_]Inst{
        asm_.closureMake(0, 0, 0),
        asm_.returnSlot(0),
    };
    const routine = Routine{
        .code = &code,
        .consts = &consts,
        .capture_descs = &.{}, // empty
        .slot_count = 1,
    };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.OperandOutOfRange, res);
}

// ---- step 5b: cell operations + U-operand tests ----

test "VM 5b: closure:box-local wraps slot value into an UpvalCell" {
    // Load 42 into s0, box it, then verify s0 holds a cell and
    // the cell's value is 42.
    const consts = [_]Const{cval(value_mod.fromFixnum(42).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.closureBoxLocal(0),
        asm_.returnSlot(0), // return the cell value (we'll inspect via VM state, not result)
    };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 1 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    // After box-local, the slot (now returned as result) is a cell-internal Value.
    try testing.expect(result.kind() == value_mod.Kind.cell_internal);
    const cell = try VM.asCell(result);
    try testing.expect(cell.initialized);
    try testing.expectEqual(@as(i64, 42), cell.value.asFixnum());
}

test "VM 5b: closure:box-local on already-boxed slot traps :invalid-cell-state" {
    const consts = [_]Const{cval(value_mod.fromFixnum(7).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.closureBoxLocal(0), // first box
        asm_.closureBoxLocal(0), // second box — must trap
        asm_.returnSlot(0),
    };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 1 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidCellState, res);
}

test "VM 5b: closure:get-cell reads cell contents back" {
    const consts = [_]Const{cval(value_mod.fromFixnum(99).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.closureBoxLocal(0),
        asm_.closureGetCell(1, 0), // s1 = *cell at s0
        asm_.returnSlot(1),
    };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 2 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 99), result.asFixnum());
}

test "VM 5b: closure:get-cell on non-cell traps :expected-cell" {
    const consts = [_]Const{cval(value_mod.fromFixnum(5).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0), // s0 = fixnum 5 (NOT a cell)
        asm_.closureGetCell(1, 0),
        asm_.returnSlot(1),
    };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 2 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.ExpectedCell, res);
}

test "VM 5b: mov:move with U-operand source resolves cell contents (no opcode needed)" {
    // Per peer-AI turn 34: no dedicated closure:read-upval —
    // resolve(u:N) deref's the cell. Test it via a hand-assembled
    // single-frame routine where we manually populate frame.upvalues.
    var child_code = [_]Inst{
        asm_.moveFrom(0, Operand.upvalue(0)), // s0 = u:0 (deref)
        asm_.returnSlot(0),
    };
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 1,
        .fixed_arity = 0,
        .upvalue_count = 1,
    };

    // Set up VM with a top-level routine that calls the child.
    // We need closure:make to provide an upvalue, which means
    // we need to first box a local. Use box + make + call.
    var parent_consts_storage = [_]Const{
        cval(value_mod.fromFixnum(123).?),
        croutine(&child_routine),
    };
    const parent_caps = [_]CaptureDescriptor{
        .{ .sources = &[_]CaptureSource{.{ .local_cell_slot = 0 }} },
    };
    var parent_code = [_]Inst{
        asm_.loadConst(0, 0), //                 s0 = 123
        asm_.closureBoxLocal(0), //              s0 = *cell{123}
        asm_.closureMake(1, 0, 1), //            s1 = closure capturing cell at s0
        asm_.callCall(1, 0, 2), //               s2 = (child) — child returns 123 via U deref
        asm_.returnSlot(2),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts_storage,
        .capture_descs = &parent_caps,
        .slot_count = 3,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 123), result.asFixnum());
}

test "VM 5b: U-operand out of range traps :upvalue-out-of-range" {
    // Child routine has upvalue_count=0 but tries to read u:0.
    var child_code = [_]Inst{
        asm_.moveFrom(0, Operand.upvalue(0)),
        asm_.returnSlot(0),
    };
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 1,
        .fixed_arity = 0,
        .upvalue_count = 0,
    };

    var parent_consts = [_]Const{croutine(&child_routine)};
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var parent_code = [_]Inst{
        asm_.closureMake(0, 0, 0),
        asm_.callCall(0, 0, 1),
        asm_.returnSlot(1),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 2,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.UpvalueOutOfRange, res);
}

test "VM 5b: closure:make with local_cell_slot source populates closure.upvalues" {
    // Standalone test of closure:make's descriptor execution
    // (the existing 5a1 closure:make tests all used empty
    // descriptors). Box a slot, then closure:make with one
    // local_cell_slot source. Verify closure.upvalues has the
    // right cell.
    var child_code = [_]Inst{asm_.returnNil()};
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 1,
        .fixed_arity = 0,
        .upvalue_count = 1,
    };
    const consts = [_]Const{
        cval(value_mod.fromFixnum(42).?),
        croutine(&child_routine),
    };
    const caps = [_]CaptureDescriptor{
        .{ .sources = &[_]CaptureSource{.{ .local_cell_slot = 0 }} },
    };
    var code = [_]Inst{
        asm_.loadConst(0, 0), //         s0 = 42
        asm_.closureBoxLocal(0), //      s0 = *cell{42}
        asm_.closureMake(1, 0, 1), //    s1 = closure with upvalue[0] = cell
        asm_.returnSlot(1),
    };
    const routine = Routine{
        .code = &code,
        .consts = &consts,
        .capture_descs = &caps,
        .slot_count = 2,
    };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .function);
    const closure = VM.asClosure(result);
    try testing.expectEqual(@as(usize, 1), closure.upvalues.len);
    try testing.expectEqual(@as(i64, 42), closure.upvalues[0].value.asFixnum());
    try testing.expect(closure.upvalues[0].initialized);
}

// ---- step 5c: placeholder cell tests ----

test "VM 5c: closure:new-cell creates uninitialized cell" {
    var code = [_]Inst{
        asm_.closureNewCell(0),
        asm_.returnSlot(0),
    };
    const routine = Routine{ .code = &code, .consts = &.{}, .slot_count = 1 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == value_mod.Kind.cell_internal);
    const cell = try VM.asCell(result);
    try testing.expect(!cell.initialized);
}

test "VM 5c: U-operand resolve on uninitialized cell traps :uninitialized-cell" {
    // Construct a closure with a single upvalue pointing to an
    // uninitialized cell. Inner fn body tries to read it via
    // u:0, which deref's the cell — should trap.
    var child_code = [_]Inst{
        asm_.moveFrom(0, Operand.upvalue(0)),
        asm_.returnSlot(0),
    };
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 1,
        .fixed_arity = 0,
        .upvalue_count = 1,
    };
    var parent_consts = [_]Const{croutine(&child_routine)};
    const parent_caps = [_]CaptureDescriptor{
        .{ .sources = &[_]CaptureSource{.{ .local_cell_slot = 0 }} },
    };
    var parent_code = [_]Inst{
        asm_.closureNewCell(0), //         s0 = uninit cell
        asm_.closureMake(0, 0, 1), //      s1 = closure capturing s0
        asm_.callCall(1, 0, 2), //         call closure → child traps
        asm_.returnSlot(2),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 3,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.UninitializedCell, res);
}

test "VM 5c: closure:init-cell flips initialized=true and stores value" {
    const consts = [_]Const{cval(value_mod.fromFixnum(42).?)};
    var code = [_]Inst{
        asm_.closureNewCell(0), //                     s0 = uninit cell
        asm_.closureInitCell(0, Operand.constant(0)), // init s0 with 42
        asm_.closureGetCell(1, 0), //                  s1 = *s0 = 42
        asm_.returnSlot(1),
    };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 2 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "VM 5c: closure:init-cell on already-initialized cell traps :invalid-cell-state" {
    const consts = [_]Const{cval(value_mod.fromFixnum(1).?)};
    var code = [_]Inst{
        asm_.closureNewCell(0),
        asm_.closureInitCell(0, Operand.constant(0)), // first init OK
        asm_.closureInitCell(0, Operand.constant(0)), // second init traps
        asm_.returnNil(),
    };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 1 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidCellState, res);
}

test "VM 5c: closure:init-cell with non-slot A traps :invalid-operand-kind" {
    // Per peer-AI turn 46: validate destination operand kind
    // before any reads or writes.
    const consts = [_]Const{cval(value_mod.fromFixnum(1).?)};
    var code = [_]Inst{
        Inst.primary(
            .closure,
            Closure_.init_cell,
            Operand.constant(0), // A=constant — invalid for init-cell dst
            Operand.constant(0),
            Operand.none,
        ),
        asm_.returnNil(),
    };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 1 };
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

test "VM 5c: closure:init-cell on non-cell traps :expected-cell" {
    const consts = [_]Const{cval(value_mod.fromFixnum(7).?)};
    var code = [_]Inst{
        asm_.loadConst(0, 0), //                       s0 = 7 (fixnum, not a cell)
        asm_.closureInitCell(0, Operand.constant(0)),
        asm_.returnNil(),
    };
    const routine = Routine{ .code = &code, .consts = &consts, .slot_count = 1 };

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.ExpectedCell, res);
}

test "VM 5c: placeholder pattern — new-cell + make + init enables self-recursion" {
    // End-to-end: build a closure that captures itself via the
    // placeholder pattern. Closure body just returns its
    // upvalue (the closure itself). Calling the closure
    // returns ... the closure itself.
    //
    // (fn* foo [] foo) — when called, returns foo.
    var child_code = [_]Inst{
        asm_.moveFrom(0, Operand.upvalue(0)), // s0 = u:0 = closure
        asm_.returnSlot(0),
    };
    const child_routine = Routine{
        .code = &child_code,
        .consts = &.{},
        .slot_count = 1,
        .fixed_arity = 0,
        .upvalue_count = 1,
    };
    var parent_consts = [_]Const{croutine(&child_routine)};
    const parent_caps = [_]CaptureDescriptor{
        .{ .sources = &[_]CaptureSource{.{ .local_cell_slot = 0 }} },
    };
    var parent_code = [_]Inst{
        asm_.closureNewCell(0), //                       s0 = uninit cell
        asm_.closureMake(0, 0, 1), //                    s1 = closure capturing s0
        asm_.closureInitCell(0, Operand.slot(1)), //     s0's cell = s1 (the closure)
        asm_.callCall(1, 0, 2), //                       s2 = (closure) → returns closure
        asm_.returnSlot(2),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 3,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const result = try vm.run();
    // Result should be a closure (kind .function).
    try testing.expect(result.kind() == .function);
    // Specifically, it should be the SAME closure we constructed
    // (same routine pointer).
    const c = VM.asClosure(result);
    try testing.expectEqual(&child_routine, c.routine);
}

test "VM 5a1: same closure called twice — both invocations succeed" {
    // Child returns its single arg incremented by 1.
    const child_consts = [_]Const{cval(value_mod.fromFixnum(1).?)};
    var child_code = [_]Inst{
        asm_.mathAdd(1, Operand.slot(0), Operand.constant(0)),
        asm_.returnSlot(1),
    };
    const child_routine = Routine{
        .code = &child_code,
        .consts = &child_consts,
        .slot_count = 2,
        .fixed_arity = 1,
    };
    // Parent: make closure, call with 5 → s4. Reuse closure, call
    // with 10 → s5. Add s4 + s5 → result.
    const parent_consts = [_]Const{
        croutine(&child_routine),
        cval(value_mod.fromFixnum(5).?),
        cval(value_mod.fromFixnum(10).?),
    };
    const parent_caps = [_]CaptureDescriptor{.{ .sources = &.{} }};
    var parent_code = [_]Inst{
        asm_.closureMake(0, 0, 0), // s0 = closure
        asm_.loadConst(1, 1), //         s1 = 5
        asm_.callCall(0, 1, 4), //       s4 = closure(5) = 6

        // Reuse closure (s0 still holds it). Stage second call.
        asm_.loadConst(1, 2), //         s1 = 10
        asm_.callCall(0, 1, 5), //       s5 = closure(10) = 11

        asm_.mathAdd(6, Operand.slot(4), Operand.slot(5)), // s6 = 6 + 11 = 17
        asm_.returnSlot(6),
    };
    const parent_routine = Routine{
        .code = &parent_code,
        .consts = &parent_consts,
        .capture_descs = &parent_caps,
        .slot_count = 7,
    };

    var vm = try VM.init(testing.allocator, &parent_routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 17), result.asFixnum());
}

test "VM math:add: unimplemented variant (sub) returns UnimplementedOpcode" {
    // math:sub (variant 1) is reserved per PLAN §12.3 but not
    // wired in this commit. Dispatch must surface
    // UnimplementedOpcode, not BytecodeCorruption.
    const math_sub: Inst = .{
        .kind = .primary,
        .group = @intFromEnum(Group.math),
        .variant = 1,
        .a = Operand.slot(0),
        .b = Operand.slot(0),
        .c = Operand.slot(0),
    };
    var code = [_]Inst{ math_sub, asm_.returnNil() };
    const routine = makeRoutine(&code, &.{}, 1, "math-sub-unimpl");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.UnimplementedOpcode, res);
}

test "VM: a multi-step routine round-trips values through slots" {
    // Load three fixnum constants into three slots, then pick the
    // middle one as the return value. Exercises the instruction loop
    // across multiple dispatches.
    const consts = [_]Const{
        cval(value_mod.fromFixnum(10).?),
        cval(value_mod.fromFixnum(20).?),
        cval(value_mod.fromFixnum(30).?),
    };
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.loadConst(1, 1),
        asm_.loadConst(2, 2),
        asm_.move(3, 1),
        asm_.returnSlot(3),
    };
    const routine = makeRoutine(&code, &consts, 4, "multi-step");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 20), result.asFixnum());
}
