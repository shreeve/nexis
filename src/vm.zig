//! vm.zig — the bytecode interpreter.
//!
//! Spec: `docs/VM.md`. This file holds:
//!
//!   - The 64-bit instruction encoding (`Inst`, `Operand`) and the
//!     opcode groups the two-level `dispatch` switch understands.
//!   - `Routine`, a unit of compiled code with its constant pool,
//!     and `Closure`, a routine plus captured upvalue cells.
//!   - `Frame`s that window one shared backing `stack`; a call
//!     grows the stack into the callee's window and a return or an
//!     unwind restores the length the frame recorded on entry.
//!   - The handler stack behind `try`/`catch`/`finally`/`throw`,
//!     shared by bytecode throws and by natives (`throwValue`).
//!   - The numeric tower (`numAdd` … `numCompare`): the single
//!     implementation behind the `math:*` and `cmp:*` opcodes and
//!     the arithmetic natives.
//!   - `lookup`, the one implementation of `get`, `(:k m)`,
//!     `(m :k)`, `(s x)` and `(v i)`.
//!   - Namespaces, Vars and the namespace registry.

const std = @import("std");
const value_mod = @import("value.zig");
/// The VM owns the `Heap` every runtime value lives on: rest-arg
/// lists, the collections `coll:*` builds, closures and upvalue
/// cells, and everything the natives and the compiler allocate
/// through `ensureHeap` / `registry.heap`.
const heap_mod = @import("heap.zig");
/// The collector. The VM is its host (VM.md §9, GC.md §3): it
/// enumerates the roots, traces closures and cells, and decides
/// when a cycle is due.
const gc_mod = @import("gc.zig");
const bignum_mod = @import("bignum.zig");
const list_mod = @import("coll/list.zig");
const vector_mod = @import("coll/vector.zig");
const champ_mod = @import("coll/champ.zig");
/// Canonical `hashValue` + `equal` entry points for map and set
/// construction.
const dispatch_mod = @import("dispatch.zig");
/// One shared `Interner` per VM keeps symbol and keyword identity
/// consistent between the compiler, the macroexpander and runtime
/// values.
const intern_mod = @import("intern.zig");
const protocol_mod = @import("protocol.zig");
const record_mod = @import("record.zig");
const nextomic_handle = @import("nextomic/handle.zig");
const stack_guard = @import("stack.zig");
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
    /// V — namespace Var (`routine.var_table[i]`).
    var_ = 2,
    /// U — closure upvalue (`frame.upvalues[i]`).
    upvalue = 3,
    /// I — intern id (keyword/symbol). No opcode resolves it;
    /// `resolve` raises `UnimplementedOpcode`.
    intern = 4,
    /// J — bytecode offset (jump target). Used by `jump:*` and
    /// `ctrl:*`.
    jump = 5,
    /// E — durable ref literal. No opcode resolves it;
    /// `resolve` raises `UnimplementedOpcode`.
    durable = 6,
    // 7..14 reserved.
    /// Sentinel for "no operand".
    unused = 15,
    /// Non-exhaustive marker: bytecode may carry operand kinds
    /// this VM doesn't recognize. Dispatch code
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

    /// V-kind operand referencing `routine.var_table[i]`.
    pub fn varRef(i: u12) Operand {
        return .{ .kind = .var_, .index = i };
    }
};

/// Instruction kind discriminator — primary vs extension (per PLAN
/// §12.1). Extension packs 20-bit operand indices for programs that
/// exceed the 12-bit primary-operand range. Extension is not
/// implemented: an extension instruction raises `UnimplementedOpcode`.
pub const InstKind = enum(u4) {
    primary = 0,
    extension = 1,
    _,
};

/// Opcode group (6 bits). Full taxonomy per PLAN §12.3 and
/// VM.md §10. `transient`, `hash`, `tx`, `io` and `simd` have no
/// implemented variants; dispatching them raises
/// `UnimplementedOpcode`.
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
    _,
};

/// Variants for the `call` group.
pub const Call = enum(u6) {
    call = 0,
    tailcall = 1,
    @"return" = 2,
    return_nil = 3,
    _,
};

/// Variants for the `closure` group. Per VM.md §10.4.
pub const Closure_ = enum(u6) {
    make = 0,
    box_local = 1,
    new_cell = 2,
    init_cell = 3,
    get_cell = 4,
    _,
};

/// Variants for the `jump` group. Per PLAN §12.3 / VM.md §10.5.
/// `if-true` pairs with `if-false` so the compiler can choose
/// whichever produces shorter code per branch direction.
pub const Jump = enum(u6) {
    jmp = 0,
    if_true = 1,
    if_false = 2,
    _,
};

/// Variants for the `ctrl` group. Per VM.md §10 group #11 +
/// §12 try/catch/throw spec.
///
/// `halt` variant (5) is unused — the top-level `call:return`
/// path halts the VM. Uncaught throw halts via
/// `VmError.UncaughtThrow`.
pub const CtrlOp = enum(u6) {
    /// `ctrl:try-enter A=catch_pc B=binding_slot C=finally_pc?` —
    /// push a try handler. catch_pc is absolute. binding_slot
    /// is where the thrown value will be stored when the catch
    /// fires. C is either a `.jump` operand carrying the
    /// absolute finally_pc or `.unused`.
    try_enter = 0,
    /// `ctrl:try-exit A=post_pc B=unused C=unused` — pop the
    /// current handler/cleanup (must belong to this frame) and
    /// jump to post_pc. If the popped handler has a finally_pc,
    /// the VM redirects through the finally body with a saved
    /// post_pc continuation.
    try_exit = 1,
    /// `ctrl:finally-exit` — pop the finally continuation and
    /// dispatch on it (`.normal` → resume at post_pc,
    /// `.throwing` → continue unwinding).
    finally_exit = 2,
    /// `ctrl:throw A=value_operand B=unused C=unused` — throw
    /// the resolved value. A may be any operand kind (slot,
    /// constant, var). Walks the handler stack; if a try
    /// handler matches, replaces it with a cleanup handler
    /// (this prevents the catch body from being re-caught by
    /// its own handler),
    /// binds the thrown value, and jumps to catch_pc. If no
    /// handler matches in any frame, halts with
    /// `VmError.UncaughtThrow`.
    throw_ = 3,
    /// Reserved.
    halt_ = 5,
    _,
};

/// Variants for the `coll` group. Per VM.md §10 group #7. `list`
/// and `concat` are the runtime substrate for syntax-quote's
/// `(#%list ...)` / `(#%concat ...)` output. Every variant takes
/// a slot-block (A=base, B=argc, C=dst) and builds a value via
/// `VM.heap`.
pub const CollOp = enum(u6) {
    /// `coll:list A=arg_base B=argc C=dst` — build a list from
    /// argc consecutive slots starting at A. Empty list (argc=0)
    /// is the canonical empty value per `list_mod.empty(heap)`.
    list = 0,
    /// `coll:concat A=arg_base B=argc C=dst` — each arg slot
    /// holds a seqable (nil, list, vector, map or set); result is
    /// the list of their elements left to right, a map
    /// contributing `[k v]` entries. Empty concat (argc=0) returns
    /// the empty list. Any other kind traps `KindMismatch`.
    concat = 1,
    /// `coll:vector A=arg_base B=argc C=dst` —
    /// build a persistent vector from argc consecutive slots.
    /// Empty vector (argc=0) via `vector_mod.empty(heap)`.
    /// Allocates via `vector_mod.fromSlice` for argc>0.
    vector = 2,
    /// `coll:map A=arg_base B=argc C=dst` — build
    /// a persistent map from argc slots interpreted as flat
    /// k,v,k,v,... pairs. argc MUST be even
    /// (BytecodeCorruption otherwise — compiler guarantees
    /// this). Duplicate keys: later wins (Clojure semantics).
    /// Hash + equality come from dispatch.hashValue +
    /// dispatch.equal.
    map = 3,
    /// `coll:set A=arg_base B=argc C=dst` — build
    /// a persistent set from argc slot values. Duplicates
    /// collapse (set semantics). Same hash/eq machinery as
    /// `coll:map`.
    set = 4,
    _,
};

/// Variants for the `var` group. Per VM.md §10 group #6.
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

/// Variants for the `cmp` group. Per VM.md §10 group #1
/// (comparisons live in their own group, NOT in `math`, to keep
/// the arithmetic ISA clean). All five dispatch through
/// `numCompare`.
pub const Cmp = enum(u6) {
    lt = 0,
    lte = 1,
    gt = 2,
    gte = 3,
    eq_num = 4,
    _,
};

/// Variants for the `math` group. Per PLAN §12.3 / VM.md §10.
/// Every variant except `pow` dispatches through the numeric
/// tower; `pow` raises `UnimplementedOpcode`. A variant outside
/// this enum raises `BytecodeCorruption` ("known opcode, not
/// wired" and "unrecognized bit pattern" are distinct errors).
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
// Routine is a plain Zig struct referenced by `*const Routine`
// from constant pools and closures; it is not a heap Value.
// =============================================================================

/// Typed entry in a routine's constant pool.
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
/// (Per VM.md §6 capture descriptor sources.)
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
/// constructed closure.
pub const CaptureDescriptor = struct {
    sources: []const CaptureSource,
};

/// A byte range of a source text: the span the reader gives a Form,
/// carried by the compiler to the instructions lowered from it.
pub const SourceSpan = struct {
    pos: u32,
    len: u32,
};

/// One run of instructions lowered from the same form: every pc
/// from `pc` up to the next entry's pc carries `span`.
pub const SpanEntry = struct {
    pc: u32,
    span: SourceSpan,
};

/// The text a routine was compiled from and the path it is reported
/// under. Owned by whoever compiled the routine and outlives it.
pub const SourceInfo = struct {
    path: []const u8,
    text: []const u8,

    pub const LineCol = struct { line: u32, col: u32 };

    /// 1-based line and column of byte offset `pos`; an offset past
    /// the end lands on the last position.
    pub fn lineCol(self: *const SourceInfo, pos: u32) LineCol {
        var line: u32 = 1;
        var col: u32 = 1;
        const cap: usize = @min(pos, self.text.len);
        for (self.text[0..cap]) |ch| {
            if (ch == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }

    /// The text of 1-based `line` without its newline; empty past
    /// the end.
    pub fn lineText(self: *const SourceInfo, line: u32) []const u8 {
        var current: u32 = 1;
        var start: usize = 0;
        for (self.text, 0..) |ch, i| {
            if (ch == '\n') {
                if (current == line) return self.text[start..i];
                current += 1;
                start = i + 1;
            }
        }
        if (current == line) return self.text[start..];
        return "";
    }
};

pub const Routine = struct {
    /// Bytecode instructions.
    code: []const Inst,
    /// Per-routine typed constant pool. Constant operands (`C#`)
    /// index into this array; the operand-using opcode determines
    /// which `Const` variant is required.
    consts: []const Const,
    /// Capture-descriptor table. Indexed by `closure:make`'s
    /// operand B per VM.md §5.
    capture_descs: []const CaptureDescriptor = &.{},
    /// Slot count. The frame reserves this many `Value` slots on
    /// invocation.
    slot_count: u16,
    /// Number of FIXED arguments this routine accepts. For a
    /// non-variadic routine, `call:call` must pass exactly
    /// `fixed_arity` args; mismatch raises `:arity-mismatch`.
    /// For a variadic routine
    /// (`variadic = true`), `call:call` must pass at least
    /// `fixed_arity` args and the rest are packed into a list
    /// installed at `slot[fixed_arity]` by the VM at call
    /// time (per VM.md §6).
    fixed_arity: u16 = 0,
    /// If true, this routine takes a rest parameter at slot
    /// `fixed_arity`. The VM packs any excess args into a list
    /// at call time. `(fn* [a b & r] body)` lowers to
    /// `fixed_arity = 2, variadic = true`.
    variadic: bool = false,
    /// Number of upvalue cells the routine's body expects in
    /// its callee frame. Validated against the constructed
    /// closure's upvalue array length at `call:call` time and
    /// against `closure:make`'s descriptor source count at
    /// closure-construction time.
    upvalue_count: u16 = 0,
    /// Per-routine Var table. The V operand index
    /// resolves through this table (analogous to const_pool
    /// for Values, capture_descs for closure construction).
    /// The compiler (compileSymbol fall-through) interns
    /// each referenced Var in the VM's Namespace and records
    /// the *Var here. Resolution is O(1) at runtime.
    var_table: []const *Var = &.{},
    /// Human-readable name for diagnostics. Non-owning.
    name: []const u8 = "<anonymous>",
    /// PC → source span table, run-length encoded and ascending by
    /// pc; empty for a routine built from hand-written Tiny or
    /// bytecode. Never consulted while instructions execute: the
    /// error path and the disassembler read it.
    spans: []const SpanEntry = &.{},
    /// The span of the form the routine was lowered from.
    origin: ?SourceSpan = null,
    /// The source the spans index into.
    source: ?*const SourceInfo = null,

    /// The source span of the instruction at `pc`, or null when the
    /// table has no entry at or before it.
    pub fn spanAt(self: *const Routine, pc: u32) ?SourceSpan {
        var lo: usize = 0;
        var hi: usize = self.spans.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.spans[mid].pc <= pc) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        return self.spans[lo - 1].span;
    }
};

/// A Var holds a mutable cell of a Value with stable identity
/// across rebinds (matches Clojure's `def` semantics: `(def x 5)`
/// then `(def x 10)` does NOT create a new Var; the same Var
/// object's root is updated). Per PLAN §6.1 + VM.md §6.
///
/// Allocation: a Var lives in VM.runtime_arena for the VM's
/// life and the Value payload is the raw `*Var`, not a
/// `HeapHeader`-prefixed heap object. Vars are immortal by
/// design (a namespace never removes one), so the collector
/// does not sweep them; it reaches their `root`, `meta` and
/// `thread_value` through the namespace walk (GC.md §3).
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
    /// resolve. Written by `var:store-var`.
    root: Value = value_mod.nilValue(),
    /// True once `def` has set the root. Distinguishes
    /// "intentionally nil" from "never bound".
    bound: bool = false,
    /// True when this Var was created by `(defmacro ...)`.
    /// The expander dispatches
    /// macro Vars (compile-time evaluation of the macro fn)
    /// instead of compiling `(my-macro ...)` as an ordinary
    /// call. Set ONLY by the expander's defmacro handler;
    /// regular `def` never sets it.
    macro: bool = false,
    /// The metadata map, or nil: `^meta` on the name, a docstring
    /// and an attribute map land here through `reset-meta!`.
    meta: Value = value_mod.nilValue(),
    /// True once the Var's metadata has carried `:dynamic true`
    /// (`(def ^:dynamic *x* ...)`); only a dynamic Var can be
    /// rebound by `binding`. Never cleared.
    dynamic: bool = false,
    /// The binding in force when `thread_bound` is true: what a
    /// load returns instead of `root`. Pushed by `binding`
    /// (`VM.pushBindings`), written by `set!`, restored by the pop.
    thread_value: Value = value_mod.nilValue(),
    thread_bound: bool = false,
};

/// A namespace mapping symbol names to `*Var`. A VM holds one
/// or more namespaces through `NamespaceRegistry`; a bare
/// `Namespace` without a registry is the single-namespace form
/// the tests use.
///
/// Lifetime: Var structs themselves live in VM.runtime_arena
/// and are freed wholesale at `VM.deinit`. The HashMap's
/// internal storage uses the same allocator the VM uses for
/// its other ArrayLists (VM.allocator); freed in
/// `Namespace.deinit`.
pub const Namespace = struct {
    /// Namespace name. Empty for ad-hoc single-ns usage (tests
    /// that construct a Namespace directly without going through
    /// `NamespaceRegistry`). When non-empty, this is the
    /// canonical name (e.g., "nexis.core", "user", "my.app").
    name: []const u8 = "",
    /// Auto-refer fallback. When `lookup` doesn't
    /// find a Var by name in this namespace, it walks the
    /// parent chain. Used to thread `nexis.core` into every
    /// user-defined namespace (`nexis.core` is auto-referred
    /// from every new namespace).
    /// `intern` does NOT walk parent — forward references
    /// always land in the current namespace, never silently
    /// shadowing parent Vars.
    parent: ?*Namespace = null,
    /// Back-link to the owning registry. Lets
    /// arbitrary cross-namespace qualified lookups (`other/x`
    /// where `other` is not an ancestor) resolve directly via
    /// `registry.lookupNs(name)`. Null for ad-hoc namespaces
    /// constructed without going through `NamespaceRegistry`.
    registry: ?*NamespaceRegistry = null,
    /// Per-namespace alias table. Maps alias name
    /// (e.g., "m") to the canonical namespace name (e.g.,
    /// "my.app"). Populated by `(require '[my.app :as m])` in
    /// the CURRENT namespace. Qualified symbol resolution
    /// (`compileQualifiedSymbol`) checks aliases BEFORE
    /// treating the prefix as a literal namespace name. Aliases
    /// are namespace-local (not inherited via auto-refer).
    aliases: std.StringHashMap([]const u8) = undefined,
    aliases_initialized: bool = false,
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
            .aliases = std.StringHashMap([]const u8).init(map_allocator),
            .aliases_initialized = true,
        };
    }

    pub fn deinit(self: *Namespace) void {
        // Var structs are arena-owned; freed wholesale at
        // VM.deinit. Only the hash map's internal storage
        // belongs to us here.
        self.vars.deinit(self.map_allocator);
        if (self.aliases_initialized) self.aliases.deinit();
        self.* = undefined;
    }

    /// Register an alias `alias_name → target_ns_name`
    /// in this namespace's alias table. Used by
    /// `(require '[my.ns :as alias])`. Replaces any existing
    /// binding for `alias_name`. Both strings are duped into
    /// var_allocator (stable for the namespace's lifetime)
    /// since the caller's slices may live in a per-form arena
    /// that dies before the next lookup.
    pub fn putAlias(self: *Namespace, alias_name: []const u8, target_ns_name: []const u8) !void {
        const owned_alias = try self.var_allocator.dupe(u8, alias_name);
        const owned_target = try self.var_allocator.dupe(u8, target_ns_name);
        try self.aliases.put(owned_alias, owned_target);
    }

    /// Resolve an alias name. Returns the target
    /// namespace name if `name` is registered as an alias in
    /// this namespace, else null.
    pub fn lookupAlias(self: *const Namespace, name: []const u8) ?[]const u8 {
        return self.aliases.get(name);
    }

    /// Look up an existing Var. Returns null if no Var was
    /// ever interned under `name` in this namespace OR in any
    /// auto-referred parent.
    pub fn lookup(self: *const Namespace, name: []const u8) ?*Var {
        if (self.vars.get(name)) |v| return v;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    /// Local-only lookup. Does NOT walk parent.
    /// Used by interner-style fall-through where a forward-
    /// reference Var should ONLY land in the current
    /// namespace, never in a referred-in parent.
    pub fn lookupLocal(self: *const Namespace, name: []const u8) ?*Var {
        return self.vars.get(name);
    }

    /// Get or create a Var for `name`. Newly-created Vars are
    /// unbound (root = nil, bound = false). The compiler uses
    /// this for forward references.
    ///
    /// The name is duped into `var_allocator` so callers can
    /// pass slices from transient arenas (e.g., a per-form
    /// reader arena that dies after `(require ...)` loads a
    /// file); loader-driven interning depends on this dupe.
    pub fn intern(self: *Namespace, name: []const u8) !*Var {
        if (self.vars.get(name)) |v| return v;
        const owned_name = try self.var_allocator.dupe(u8, name);
        const new_var = try self.var_allocator.create(Var);
        new_var.* = .{ .name = owned_name };
        try self.vars.put(self.map_allocator, owned_name, new_var);
        return new_var;
    }
};

/// Multi-namespace registry. Owns
/// a map from canonical namespace name to `*Namespace`, plus
/// pointers to the conventional `nexis.core` (auto-referred by
/// every new namespace) and the `current` namespace (where
/// `def`/`defn`/`defmacro` install).
///
/// Lifetime: Namespaces are arena-allocated (typically into
/// `VM.runtime_arena`); the registry's HashMap uses
/// `map_allocator` for its own internal storage and is
/// `deinit`-ed by the registry's owner.
pub const NamespaceRegistry = struct {
    map_allocator: std.mem.Allocator,
    /// Allocator for Namespace structs + their Var children.
    /// Typically `VM.runtime_arena.allocator()`.
    var_allocator: std.mem.Allocator,
    /// Map of canonical ns name → namespace pointer.
    map: std.StringHashMap(*Namespace) = undefined,
    /// Auto-referred fallback for every new namespace.
    core: *Namespace = undefined,
    /// Where `def`/`defn`/`defmacro` install.
    current: *Namespace = undefined,
    /// Heap reachable from the compile.zig Form-lowering path
    /// via `namespace.registry.heap`. Used by `LowerCtx.heap` to
    /// allocate string-literal Values (Tiny.literal carriers).
    /// `VM.ensureRegistry` populates this from `VM.ensureHeap()`.
    /// Ad-hoc test harnesses that init a registry without a VM
    /// can leave it null; `.string` Forms then raise
    /// `UnsupportedFeature`. The registry is the channel that
    /// carries the heap to the compiler; there is no bundled
    /// compile-context struct.
    heap: ?*heap_mod.Heap = null,

    /// Two-phase init: caller stores the empty registry FIRST,
    /// then calls `setupDefaults` on the stable pointer.
    /// Single-phase init would be unsafe: `ns.registry = self`
    /// would capture a local `self` pointer that dangles once
    /// the registry is copied into its final home.
    pub fn initEmpty(
        map_allocator: std.mem.Allocator,
        var_allocator: std.mem.Allocator,
    ) NamespaceRegistry {
        return .{
            .map_allocator = map_allocator,
            .var_allocator = var_allocator,
            .map = std.StringHashMap(*Namespace).init(map_allocator),
            .core = undefined,
            .current = undefined,
            .heap = null,
        };
    }

    /// Populate the conventional `nexis.core` (auto-referred)
    /// and `user` (default current) namespaces. Must be called
    /// on a STABLE pointer (i.e., after the registry has been
    /// stored in its final location) because each namespace
    /// captures `self` as its back-pointer.
    pub fn setupDefaults(self: *NamespaceRegistry) !void {
        self.core = try self.makeNamespace("nexis.core", null);
        self.current = try self.makeNamespace("user", self.core);
    }

    pub fn deinit(self: *NamespaceRegistry) void {
        // Namespace structs + their Vars live in `var_allocator`
        // (typically an arena); freed wholesale by the arena's
        // owner. We only own the outer HashMap + the per-
        // namespace `vars` HashMap storage (which uses
        // `map_allocator`).
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.map.deinit();
        self.* = undefined;
    }

    /// Get an existing namespace by name, or create + register
    /// a new one (with `parent` as its auto-referred fallback).
    /// `name` must be a stable slice (typically a string literal
    /// or arena-owned; the registry holds the slice by reference).
    pub fn getOrCreate(
        self: *NamespaceRegistry,
        name: []const u8,
        parent: ?*Namespace,
    ) !*Namespace {
        if (self.map.get(name)) |existing| return existing;
        return try self.makeNamespace(name, parent);
    }

    /// Look up a namespace by name. Returns null if missing.
    pub fn lookupNs(self: *const NamespaceRegistry, name: []const u8) ?*Namespace {
        return self.map.get(name);
    }

    /// Switch the current namespace pointer. If the named ns
    /// doesn't exist yet, create it with `core` as its parent
    /// (matches Clojure's `(ns NAME)` semantics for first-time
    /// declarations).
    pub fn switchTo(self: *NamespaceRegistry, name: []const u8) !void {
        const ns = try self.getOrCreate(name, self.core);
        self.current = ns;
    }

    fn makeNamespace(
        self: *NamespaceRegistry,
        name: []const u8,
        parent: ?*Namespace,
    ) !*Namespace {
        // Dupe the name into stable storage
        // (var_allocator, typically vm.runtime_arena). The caller's
        // `name` slice may be in a per-form reader arena that
        // dies after the load completes; the registry map key
        // + Namespace.name field must outlive that.
        const owned_name = try self.var_allocator.dupe(u8, name);
        const ns = try self.var_allocator.create(Namespace);
        ns.* = Namespace.init(self.map_allocator, self.var_allocator);
        ns.name = owned_name;
        ns.parent = parent;
        ns.registry = self;
        try self.map.put(owned_name, ns);
        return ns;
    }
};

/// Captured-binding cell: one Value plus an `initialized` flag
/// (per VM.md §6). Created by `closure:box-local` and
/// `closure:new-cell`, filled by `closure:init-cell`.
///
/// A cell is the body of a heap block of kind `cell_internal`
/// (VALUE.md §2.3): the `.cell_internal` Value a slot holds and
/// the `*UpvalCell` a closure or frame holds both name that
/// block. The collector traces a cell by its value through
/// `VM.gcTrace`; a cell is reachable from the slot that boxed
/// it, from every closure that captured it and from every frame
/// running such a closure.
pub const UpvalCell = struct {
    value: Value,
    initialized: bool,
};

/// Runtime closure object: a routine + its upvalue cells.
/// Per VALUE.md kind 24 = `function`.
///
/// **Representation**: the body of a heap block of kind
/// `function` whose tail holds the cell pointers; `upvalues`
/// points into that tail, which is safe because the collector
/// never moves a block. `Value.payload` is the block's
/// `*HeapHeader`, as for every heap kind (VALUE.md §4). The
/// collector traces a closure by its cells and by the heap
/// constants of its routine (`VM.gcTrace`).
pub const Closure = struct {
    routine: *const Routine,
    /// One cell per upvalue, filled by `closure:make` from the
    /// capture descriptor's sources.
    upvalues: []const *UpvalCell,
};

/// The block header of a cell reached through its body pointer.
inline fn cellHeader(cell: *UpvalCell) *heap_mod.HeapHeader {
    return @ptrFromInt(@intFromPtr(cell) - @sizeOf(heap_mod.HeapHeader));
}

/// Static descriptor for a host-Zig function exposed as a
/// first-class Value.
/// Descriptors live in STATIC storage (one `const NativeFn`
/// per fn); the Value just packs a pointer to the descriptor.
/// No heap allocation, no GC concern, immortal lifetime.
///
/// Arity semantics:
///   - `min_arity`: minimum acceptable argc.
///   - `max_arity`: null = unbounded (variadic); else max argc.
pub const NativeFn = struct {
    name: []const u8,
    min_arity: u16,
    max_arity: ?u16,
    call: *const fn (vm: *VM, args: []const Value) VmError!Value,
};

/// Unpack the descriptor pointer from a `.native_fn` Value.
pub fn asNativeFn(v: Value) *const NativeFn {
    std.debug.assert(v.kind() == .native_fn);
    return @ptrFromInt(v.payload);
}

/// Build a `.native_fn` Value from a static `NativeFn`
/// descriptor. Typical use: `vm_mod.nativeFnValue(&native_first)`.
pub fn nativeFnValue(descriptor: *const NativeFn) Value {
    return value_mod.fromNativeFnPtr(@ptrCast(descriptor));
}

// =============================================================================
// Frame (VM.md §7)
//
// Each frame is a window into the VM's shared `stack` ArrayList,
// `base_slot..base_slot + slot_count`. The range-call ABI (VM.md
// §6) windows the callee's slots over the caller's
// `[call_base + 1 .. call_base + 1 + argc]` region, so arguments
// are never copied.
//
// Discipline:
//   - Never hold a `[]Value` slice into `vm.stack.items` across an
//     operation that might grow `stack`; ArrayList reallocation
//     invalidates it. Use `slotPtr()` for one-shot access, or
//     snapshot the frame's `base_slot` into a local.
//   - Never hold a `*Frame` across `pushFrame`, for the same
//     reason. Helpers that take a frame pointer are one-shot.
// =============================================================================

// Backing-stack extent invariant
//
// Frames window into one backing stack and a callee's window
// (`base_slot .. base_slot + slot_count`) may end BELOW a wider
// caller's or grandparent's window, so no single frame's extent
// says how long the stack must be. The rule is per frame:
//
//   - On entry to a frame, `entry_stack_len` records
//     `stack.items.len` as it was before the frame's window was
//     grown into it: the extent every frame beneath it requires.
//     `stack.items.len` is then `max(entry_stack_len,
//     base_slot + slot_count)`.
//   - On return, and on unwind, popping a frame restores
//     `stack.items.len` to that frame's `entry_stack_len`. An
//     unwind that pops several frames restores the lowest popped
//     frame's value, which is the extent the handler's frame set
//     requires.
//
// The top-level frame is never popped, so the harnesses that
// retarget `frames.items[0]` in place only have to keep the stack
// at least `slot_count` long.

pub const Frame = struct {
    routine: *const Routine,
    /// Index into `vm.stack.items` where this frame's slot 0 lives.
    /// Frame's slot[i] is `vm.stack.items[base_slot + i]`.
    base_slot: u32,
    /// `stack.items.len` at the moment this frame was pushed: the
    /// extent the frames beneath it require. Popping this frame,
    /// by return or by unwind, restores the stack to this length.
    entry_stack_len: u32,
    /// Logical slot count for bounds checks.
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
    /// for the top-level frame and for empty-capture closures;
    /// otherwise the array `closure:make` built, installed by
    /// `call:call`.
    upvalues: []const *UpvalCell = &.{},
    /// The closure this frame runs, nil for the top-level frame:
    /// a root that keeps the closure block (and with it the
    /// `upvalues` array in its tail) alive for the frame's life.
    closure: Value = value_mod.nilValue(),
    /// When non-null, this frame
    /// was pushed by `VM.callValue` (a host-Zig fn re-entering
    /// the VM). When `call:return` fires for this frame, it
    /// writes the return value into `host_result.value`, sets
    /// `host_result.done = true`, pops the frame, and returns
    /// WITHOUT writing into a caller slot (callValue's caller
    /// isn't a regular routine — it's host code).
    host_result: ?*HostCallResult = null,
};

/// Result cell for `VM.callValue`.
/// The synthetic frame's `call:return` handler writes into this
/// instead of into a caller's slot.
pub const HostCallResult = struct {
    done: bool = false,
    value: Value = value_mod.nilValue(),
};

/// One frame of `VM.error_trace`: the routine that was running,
/// the index of the instruction it was executing (for a caller
/// frame, the call), that instruction's source span when the
/// routine carries a span table, and the source the span indexes.
pub const TraceFrame = struct {
    name: []const u8,
    pc: u32,
    span: ?SourceSpan,
    source: ?*const SourceInfo,
};

// =============================================================================
// Errors
// =============================================================================

/// One entry per `defrecord`.
/// Names are owned by the registry (duped on registration).
/// What a native needs from the compiler at run time. `user_data`
/// belongs to the installer (the CLI runtime, a test harness); the
/// functions run on the calling VM and build their results on its
/// heap.
pub const CompilerHooks = struct {
    user_data: *anyopaque,
    /// One macro step on `form`: the expansion when `form` is a
    /// macro call, null when it is not. Expansion failures throw.
    expand_once: *const fn (*anyopaque, *VM, Value) VmError!?Value,
    /// The first form of `source` as a value; a form that does not
    /// read throws `:reader-error`.
    read_string: *const fn (*anyopaque, *VM, []const u8) VmError!Value,
    /// `form` macroexpanded and compiled in the current namespace
    /// and run on this VM as a nested call (`runRoutine`); the
    /// value it returns. A form that does not compile throws.
    eval: *const fn (*anyopaque, *VM, Value) VmError!Value,
};

pub const RecordTypeEntry = struct {
    id: u32,
    ns_name: []const u8,
    type_name: []const u8,
    /// Declared field keyword names (interned strings).
    field_names: []const []const u8,
};

/// One entry per `defprotocol`.
/// Methods table is indexed by method-name-id (interned symbol
/// id). Each method's impls map keys on DispatchKey (record
/// type_id for records, kind tag for built-in kinds — see
/// dispatchKeyOf in this module).
pub const ProtocolEntry = struct {
    id: u32,
    ns_name: []const u8,
    name: []const u8,
    methods: std.ArrayList(ProtocolMethod) = .empty,
};

pub const ProtocolMethod = struct {
    /// Interned symbol id (matches ProtocolFnBody.method_name_id).
    name_id: u32,
    /// Short copy of the method name string (owned by VM allocator)
    /// so error messages can reach the user without a re-intern.
    name: []const u8,
    /// Method impls keyed by DispatchKey. The Value is callable
    /// (closure / native_fn / etc.) and receives the protocol
    /// receiver as its first arg.
    impls: std.AutoHashMapUnmanaged(DispatchKey, Value) = .empty,
    /// Fallback impl used when no DispatchKey matches. Set by
    /// `#%extend-default-impl` (`extend-protocol` on `:any`).
    default_impl: ?Value = null,
};

/// Inline-method spec passed to `registerProtocol`. Owned by the
/// caller (slices duped on registration).
pub const ProtocolMethodSpec = struct {
    name_id: u32,
    name: []const u8,
};

/// DispatchKey: how protocol-fn dispatch finds an impl. For
/// records, we key on `(:record, type_id)`. For built-in kinds
/// we key on `(:builtin, kind_byte)`, with the integer tower one
/// key (`canonical`). PROTOCOLS.md §3.2.
pub const DispatchKey = struct {
    tag: Tag,
    id: u32,

    pub const Tag = enum(u8) {
        builtin = 0,
        record = 1,
    };

    pub fn ofValue(v: value_mod.Value) DispatchKey {
        if (v.kind() == .record) return .{ .tag = .record, .id = record_mod.typeId(v) };
        return canonical(.{ .tag = .builtin, .id = @intFromEnum(v.kind()) });
    }

    /// The integer tower is one type (SEMANTICS §2.2): a bignum
    /// dispatches on the fixnum's key, so an impl for either integer
    /// kind covers every integer whatever its representation.
    pub fn canonical(key: DispatchKey) DispatchKey {
        if (key.tag == .builtin and key.id == @intFromEnum(value_mod.Kind.bignum)) {
            return .{ .tag = .builtin, .id = @intFromEnum(value_mod.Kind.fixnum) };
        }
        return key;
    }
};

pub const VmError = error{
    /// Known opcode / group / variant / operand kind that this VM
    /// does not implement (extension instructions, the
    /// `transient`/`hash`/`tx`/`io`/`simd` groups, `call:tailcall`,
    /// `math:pow`, `ctrl:halt`, intern/durable operands).
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
    /// Bytecode exhausted without an explicit `return`. There is
    /// no implicit `return nil` at code-end.
    BytecodeExhausted,
    /// Unknown opcode group / variant / operand kind bit pattern
    /// (NOT in any recognized enum space). Indicates
    /// bytecode corruption or bytecode from a nexis VM
    /// that this VM doesn't understand.
    BytecodeCorruption,
    /// `math:*` (or other kind-sensitive op) received an operand
    /// of a kind the op does not accept (e.g., a non-numeric
    /// operand to `math:add`, a non-list operand to
    /// `coll:concat`). Mirrors the `:kind-mismatch` user-visible
    /// error kind from VM.md §13; reusing that taxonomy keeps a
    /// parallel "type-error" category from drifting in.
    KindMismatch,
    /// A count or identifier the runtime produces does not fit in
    /// a fixnum. Arithmetic never raises it: an integer result
    /// that leaves the i48 range promotes to a bignum.
    ArithmeticOverflow,
    /// Integer `/`, or `quot`/`rem`/`mod` of any kind, with a
    /// zero divisor. Float `/` by zero is IEEE (infinity / NaN)
    /// and never raises.
    DivideByZero,
    /// `call:call` / `call:tailcall` invocation passed a different
    /// number of arguments than the callee closure's routine
    /// declares. Per VM.md §13 `:arity-mismatch` row: the
    /// runtime arity check fires at
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
    /// UpvalCell, stack growth, frame push). Surfaced as a
    /// generic OutOfMemory carrying no context.
    OutOfMemory,
    /// `U` operand index exceeds the current frame's
    /// `upvalues.len`, OR a `closure:make` `inherited_upvalue`
    /// descriptor source exceeds it. Per VM.md §13
    /// `:upvalue-out-of-range`.
    UpvalueOutOfRange,
    /// An opcode that requires an `UpvalCell*` in a slot (e.g.,
    /// `closure:get-cell`, `closure:make` `local_cell_slot`
    /// source) found a different Value kind in the slot. Per
    /// VM.md §13 `:expected-cell`.
    ExpectedCell,
    /// `closure:box-local` invoked on a slot that already holds
    /// an `UpvalCell*` (double-box), OR `closure:init-cell` on
    /// an already-initialized cell. Per VM.md §13
    /// `:invalid-cell-state`. Indicates a
    /// compiler bug — should never reach the runtime.
    InvalidCellState,
    /// `closure:get-cell` (or U-operand resolve) read a cell
    /// whose `initialized = false` — a placeholder cell that
    /// has not yet been filled in. Per VM.md §13
    /// `:uninitialized-cell`. Indicates a
    /// `closure:init-cell` was emitted out of order or skipped
    /// entirely.
    UninitializedCell,

    /// A throw, from `ctrl:throw` or from a native through
    /// `throwValue`, found no handler on the handler stack. The
    /// VM halts and the thrown value is left in
    /// `VM.unhandled_throw` for the host to report.
    UncaughtThrow,
    /// Handler stack is in an invalid state —
    /// `ctrl:try-exit` referenced a handler that doesn't
    /// belong to the current frame, or popping found nothing.
    /// Indicates compiler bug, not user error.
    InvalidHandlerState,
    /// Indexed access on a collection (e.g.,
    /// `(nth coll n)`) used an out-of-bounds index. Mapped to
    /// `:index-out-of-bounds` by the catchable-error
    /// translation table.
    IndexOutOfBounds,
    /// db engine error (file open failure, missing
    /// tree, MVCC conflict, etc.). Mapped to `:db-error`.
    DbError,
    /// Operation attempted on a Connection that
    /// was already closed (via `db/close` or VM teardown).
    /// Mapped to `:db-closed`.
    DbClosed,
    /// Arg expected to be a `durable_ref` Value
    /// was not. Mapped to `:invalid-durable-ref`.
    InvalidDurableRef,
    /// Codec encode/decode failed (unserializable
    /// value, corrupt bytes, version mismatch). Mapped to
    /// `:codec-failed`.
    CodecFailed,
    /// tx op attempted on a transaction that was
    /// already committed or aborted. Mapped to `:tx-closed`.
    TxClosed,
    /// `(db/deref x)` / `@x` invoked on a Value
    /// whose kind isn't a durable_ref or Var. Mapped to
    /// `:not-derefable`.
    NotDerefable,
    /// INTERNAL control-flow
    /// signal. NOT user-visible, NOT catchable. Raised when a
    /// throw propagated past a `VM.callValue` synthetic frame
    /// (i.e., control transferred to a handler installed BELOW
    /// the callValue entry point). Native fns + HOFs that
    /// invoke `callValue` must propagate this unchanged so the
    /// outer handler's frame-rewind happens correctly. The run
    /// loop catches it and continues dispatch (PC + frame state
    /// have already been adjusted by unwindThrow).
    ControlTransferred,
    /// V-operand resolve (or `var:load-var`) read a Var whose
    /// `bound = false` — the Var was interned (e.g., by a
    /// forward reference in another `defn`) but no `def` has
    /// set its root yet. Per VM.md §13 `:unbound-var`.
    /// Recoverable error (user can `def`
    /// the var and retry).
    UnboundVar,
    /// `binding` or `set!` on a Var not marked `^:dynamic`
    /// (`:not-dynamic`).
    NotDynamic,
    /// `set!` on a dynamic Var with no binding in force
    /// (`:no-thread-binding`).
    NoThreadBinding,
    /// A mutating op on an
    /// atom (`swap!`/`reset!`/`compare-and-set!`/`swap-vals!`)
    /// was attempted while ANOTHER mutating op on the same
    /// atom is still in flight. The single-threaded VM cannot
    /// retry a `swap!`-style CAS loop, so this is reported as a
    /// catchable error instead of being silently allowed.
    /// Mapped to `:atom-re-entry`. See ATOM.md §4.4.
    AtomReEntry,
    /// Malformed UTF-8
    /// byte sequence encountered during codepoint iteration of
    /// a `.string` Value. Storage is byte-blob; the reader and
    /// codec validate on construction, but a corrupt-codec or
    /// fuzz path could produce one. Mapped to `:utf8-error`.
    Utf8Error,
    /// Argument is the right kind but an invalid value for
    /// the operation — e.g., empty delimiter for split, empty
    /// match for replace. Distinct from KindMismatch (which is
    /// for wrong-kind args). Mapped to `:invalid-argument`.
    InvalidArgument,
    /// Generic I/O failure for
    /// `slurp`/`spit`/`print`/`println`/`prn` — permissions,
    /// disk full, write failure, vm.io == null, etc. Mapped to
    /// `:io-error`.
    IoError,
    /// Target path does not exist (slurp on a
    /// missing file). Mapped to `:file-not-found`.
    FileNotFound,
    /// Path argument is structurally invalid (empty
    /// string, contains a NUL byte, etc.). Distinct from
    /// `:io-error` because the issue is at the language boundary,
    /// not in the filesystem. Mapped to `:invalid-path`.
    InvalidPath,
    /// `defrecord` with a record
    /// type name that already exists in the per-VM registry.
    /// Rejected to avoid the confusing-state hazard where
    /// existing instances reference a stale type_id.
    /// Mapped to `:record-redefinition`.
    RecordRedefinition,
    /// Record-introspection ops expected a record
    /// receiver but got something else. Mapped to `:not-a-record`.
    NotARecord,
    /// Protocol-fn dispatch could
    /// not find an impl for the receiver's dispatch key (no
    /// matching record / built-in kind impl, no Any default).
    /// Mapped to `:no-protocol-impl`.
    NoProtocolImpl,
    /// Tried to extend a protocol that does not
    /// have a method with the given name. Mapped to
    /// `:no-protocol-method`.
    NoProtocolMethod,
    /// `defprotocol` with a name that already
    /// exists (same `(ns, name)`). Mapped to
    /// `:protocol-redefinition`.
    ProtocolRedefinition,
    /// Recursion ran out of room: a call would push frame number
    /// `VM.max_frames`, or a native re-entering the VM found the
    /// native stack below the guard's limit (§13.1). Mapped to
    /// `:stack-overflow`.
    StackOverflow,
};

// =============================================================================
// Try / catch / throw machinery
// =============================================================================

/// What kind of frame-bound exception handler this is.
pub const HandlerKind = enum {
    /// A `(try body (catch any x handler))` is active —
    /// catch_pc + binding_slot are valid; throw routes here.
    try_,
    /// The catch body of a fired try is running. Keeps the
    /// handler's bookkeeping (its `finally_pc`) for the catch
    /// body's `try-exit` while making sure a throw from inside
    /// the catch body is not caught by the same handler again.
    cleanup,
};

/// Per-handler state stored on `VM.handlers`: one VM-wide stack
/// keyed by `frame_index` rather than a list per frame. Frame
/// indices stay valid across `frames.append` reallocations
/// because frames only pop from the top.
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
    /// PC of the finally entry. null when the try has no finally
    /// clause. Both .try_ and .cleanup handlers carry this so
    /// unwind through either kind runs the finally.
    finally_pc: ?u32 = null,
    /// `finally_stack.items.len` when the try was entered. Every
    /// continuation above it belongs to a finally body running inside
    /// this try, which a throw this handler takes abandons.
    finally_depth: usize,
};

/// Tagged continuation for finally bodies. When a try-exit / catch-exit / throw-unwind
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

/// The collector's trigger settings (GC.md §7). `default` is what
/// a VM starts with; `stress` is what `NEXIS_GC_STRESS` in the
/// environment selects so a run collects every few kilobytes and
/// every rooting gap shows.
pub const GcPolicy = struct {
    /// Bytes allocated since the last cycle before the next is due,
    /// at least.
    threshold: usize,
    /// The next cycle is also no sooner than this percentage of the
    /// bytes that survived the last one, so a large live set is not
    /// re-marked every few kilobytes.
    growth_percent: usize,

    pub const default: GcPolicy = .{ .threshold = 16 * 1024 * 1024, .growth_percent = 100 };
    pub const stress: GcPolicy = .{ .threshold = 4096, .growth_percent = 0 };
};

/// One entry of the dynamic-binding stack: what `v`'s thread
/// binding was before the frame that holds this entry rebound it.
pub const DynSave = struct {
    v: *Var,
    value: Value,
    bound: bool,
};

/// A window on the VM's root stack for a native that keeps values
/// across a call back into the VM: `push` what must survive a
/// collection, `release` (normally deferred) drops everything the
/// scope pushed. Scopes nest as calls do.
pub const RootScope = struct {
    vm: *VM,
    base: usize,

    pub fn push(self: RootScope, v: Value) VmError!void {
        self.vm.roots.append(self.vm.allocator, v) catch return VmError.OutOfMemory;
    }

    pub fn pushAll(self: RootScope, vs: []const Value) VmError!void {
        self.vm.roots.appendSlice(self.vm.allocator, vs) catch return VmError.OutOfMemory;
    }

    pub fn release(self: RootScope) void {
        self.vm.roots.shrinkRetainingCapacity(self.base);
    }
};

// =============================================================================
// VM
// =============================================================================

pub const VM = struct {
    allocator: std.mem.Allocator,
    /// Backing slot storage shared across all frames. Per-frame
    /// access uses `frame.base_slot + slot_index` indirection.
    stack: std.ArrayList(Value) = .empty,
    /// Frame chain. The top-level routine is frame 0;
    /// `call:call` appends; `call:return` pops.
    frames: std.ArrayList(Frame) = .empty,
    /// Runtime allocation arena for `Var` and `Namespace` objects
    /// and everything else that lives exactly as long as the VM
    /// (VM-owned allocation outside the collected heap). Freed
    /// wholesale in `deinit`.
    runtime_arena: std.heap.ArenaAllocator,
    /// The collected heap: every runtime value, closure and cell.
    /// Backed by `allocator`, so a sweep returns memory; freed
    /// block by block in `deinit`. Initialized lazily on first use
    /// so programs that never construct a value pay nothing.
    heap: ?heap_mod.Heap = null,
    /// A heap this VM allocates on instead of its own: the
    /// compile-time sub-VMs (`evalClosure`, the `defmacro`
    /// evaluation) share the heap of the VM whose Vars they read
    /// and write, so a value a macro stores into a Var outlives the
    /// sub-VM. Not owned; never freed here. A VM with a borrowed
    /// heap never collects (`gc_enabled`): it cannot enumerate the
    /// owner's roots.
    borrowed_heap: ?*heap_mod.Heap = null,
    /// Whether this VM runs the collector at its safe points
    /// (VM.md §9). False for the compile-time sub-VMs.
    gc_enabled: bool = true,
    /// The trigger (GC.md §7): a cycle is due at a safe point once
    /// `heap.allocated_since_collect` reaches `gc_next_at`, which
    /// each cycle resets to the larger of `gc_threshold` and
    /// `gc_growth_percent` percent of the bytes that survived. The
    /// defaults come from `GcPolicy`; `NEXIS_GC_STRESS` in the
    /// environment selects `GcPolicy.stress` for every VM.
    gc_threshold: usize = GcPolicy.default.threshold,
    gc_growth_percent: usize = GcPolicy.default.growth_percent,
    gc_next_at: usize = GcPolicy.default.threshold,
    /// Cycles run so far; tests read it to prove a collection
    /// happened.
    gc_cycles: usize = 0,
    /// The root stack (GC.md §3): values a native holds in Zig
    /// locals across a call back into the VM. `callValue` pushes a
    /// native callee's arguments for the call's duration; a native
    /// that accumulates results across callbacks pushes them
    /// through a `RootScope`.
    roots: std.ArrayList(Value) = .empty,
    /// The dynamic-binding stack (VM.md §6.5): one `DynSave` per
    /// Var a `binding` frame rebound, holding what the Var's thread
    /// binding was before, and one `dyn_frames` entry per frame
    /// with the index its saves start at.
    dyn_saves: std.ArrayList(DynSave) = .empty,
    dyn_frames: std.ArrayList(u32) = .empty,
    /// Single-namespace slot for Vars. Lazy-initialized on first
    /// access (no cost for programs that don't use Vars). Var
    /// structs allocate from `runtime_arena`; the HashMap's
    /// internal storage uses `allocator`. Used only when no
    /// `registry` exists (ad-hoc test harnesses).
    namespace: ?Namespace = null,
    /// Multi-namespace registry. When non-null, the
    /// CURRENT namespace is `registry.current` (which may differ
    /// across REPL evaluations or file forms via `(ns NAME)`).
    /// `ensureNamespace()` returns `registry.current` when the
    /// registry exists; otherwise it falls back to the
    /// single `namespace` field.
    registry: ?NamespaceRegistry = null,
    /// List of OPEN db Connections.
    /// `db/open` appends; `db/close` removes; `VM.deinit` closes
    /// any still-open as a safety net. Connections own OS
    /// resources (mmap, file handle); they CANNOT live in
    /// runtime_arena (which is freed wholesale).
    /// Stored as `*anyopaque` to avoid a vm.zig → db.zig
    /// dependency. db.zig owns the cast back to `*db.Connection`.
    db_connections: std.ArrayList(*anyopaque) = .empty,
    /// Closer callback. Set by db.zig the first
    /// time a connection is registered, so VM.deinit can close
    /// connections without importing db.
    db_close_callback: ?*const fn (*anyopaque) void = null,
    /// Open Nextomic connections (`nextomic/connect` appends; VM
    /// teardown destroys each through `nextomic_close_callback`). The
    /// nextomic natives own the cast, so vm.zig needs no import.
    nextomic_connections: std.ArrayList(*anyopaque) = .empty,
    nextomic_close_callback: ?*const fn (*anyopaque) void = null,
    /// The nextomic natives' per-VM state (parsed-query caches and
    /// finished `with` scopes), created on first use and destroyed at
    /// teardown through `nextomic_query_close`. The natives own the cast.
    /// `nextomic_query_clear` empties the caches, which hold query
    /// values by heap identity, after every collection
    /// (docs/NEXTOMIC.md §5).
    nextomic_query_state: ?*anyopaque = null,
    nextomic_query_close: ?*const fn (*anyopaque) void = null,
    nextomic_query_clear: ?*const fn (*anyopaque) void = null,
    /// Zig 0.16 `std.Io` handle for filesystem ops that live
    /// below the language surface —
    /// only `(db/open path)` uses it to auto-create the
    /// path's parent directories (emdb does NOT create parents).
    /// Set by the CLI (`runFile`/`runRepl`) right after
    /// `VM.init`; left null in ad-hoc test harnesses (which use
    /// absolute `/tmp` paths or pre-create dirs explicitly, so
    /// the auto-create branch is a no-op there).
    io: ?std.Io = null,

    /// Per-VM record-type
    /// registry. Lazy-init via `ensureRecordRegistry`. Each
    /// `defrecord` allocates a new RecordTypeEntry; the
    /// returned dense u32 id is used as `RecordBody.type_id`.
    /// PROTOCOLS.md §3.
    record_registry: std.ArrayList(RecordTypeEntry) = .empty,

    /// Per-VM protocol registry.
    /// Each `defprotocol` adds an entry; `extend-protocol` /
    /// inline `defrecord` impls mutate `methods[*].impls`. See
    /// PROTOCOLS.md §3.2.
    protocol_registry: std.ArrayList(ProtocolEntry) = .empty,
    /// Global try-handler stack.
    /// Push on `ctrl:try-enter`, pop on `ctrl:try-exit`,
    /// walk on `ctrl:throw`. Each Handler is keyed by
    /// `frame_index` so throw-unwind can identify which frame
    /// it belongs to.
    handlers: std.ArrayList(Handler) = .empty,
    /// Finally continuation stack. Pushed by
    /// try-exit (when the popped handler has a finally) and by
    /// throw-unwind (when a finally must run before the throw
    /// continues). Popped by finally-exit.
    finally_stack: std.ArrayList(FinallyContinuation) = .empty,
    /// The payload of the throw that halted the VM with
    /// `VmError.UncaughtThrow`; the host prints it alongside the
    /// error.
    unhandled_throw: ?Value = null,
    /// The frame chain at the moment an error left `run`, innermost
    /// first; each entry names the routine and the instruction it was
    /// executing. Rebuilt on every failing run.
    error_trace: std.ArrayList(TraceFrame) = .empty,
    /// The error `error_trace` was recorded for, so a host that
    /// learns of the failure indirectly (a `require` whose file
    /// failed while a form was being compiled) can still name it.
    traced_error: ?VmError = null,
    /// Shared Interner for symbol/keyword Value construction,
    /// initialized on first access. Backed by `self.allocator`
    /// (not `runtime_arena`) because its hash maps need realloc
    /// and free.
    interner: ?intern_mod.Interner = null,
    /// An interner this VM reads and writes instead of its own: a
    /// macro sub-VM shares the compile-time interner so the keyword
    /// and symbol ids in its arguments resolve. Not owned; never
    /// freed here.
    borrowed_interner: ?*intern_mod.Interner = null,
    /// Compile-time services a native reaches at run time
    /// (`macroexpand-1`, `read-string`). Installed by whoever boots
    /// the runtime around this VM; a bare VM has none and those
    /// natives throw `:no-compiler`.
    compiler_hooks: ?CompilerHooks = null,
    /// The record type `reduced` wraps a value in, registered on
    /// first use (`ensureReducedType`).
    reduced_type_id: ?u32 = null,
    /// Where the top-level `call:return` stores the returned Value on
    /// halt.
    result: Value = value_mod.nilValue(),
    halted: bool = false,
    /// High-water marks for the backing stack and frame stack.
    /// Used by `recur`/`loop*` tests to assert
    /// that long-running iteration runs in bounded stack space
    /// (PLAN §11.3 constant-stack guarantee). Updated on grow
    /// operations only — comparing pre/post run-loop values gives
    /// a true maximum, not just the final size (a buggy
    /// implementation could grow and shrink, leaving final size
    /// equal but high-water inflated).
    stack_high_water: usize = 0,
    frame_high_water: usize = 0,
    /// The deepest frame chain a program may build. A call that
    /// would push past it raises `StackOverflow`, so runaway
    /// recursion is a catchable `:stack-overflow` instead of memory
    /// growing until the process dies (§13).
    max_frames: usize = default_max_frames,
    /// The text of the marker `recordErrorTrace` puts where it
    /// leaves frames out.
    trace_gap: [48]u8 = undefined,
    /// What the most recent runtime error was about, for the host's
    /// report: `f takes 1 argument, got 0`, `+ expects numbers, got
    /// a string`. Set where the VM raises the error, empty when the
    /// raise site has nothing to add (natives raise without one);
    /// cleared when a run starts and when a handler takes the error
    /// as a keyword, so it never describes an earlier error.
    error_detail: []const u8 = "",
    detail_buf: [160]u8 = undefined,

    pub const default_max_frames = 1 << 20;
    /// A trace keeps this many innermost frames and
    /// `trace_outermost` outermost ones; a marker frame counts the
    /// rest.
    const trace_innermost = 32;
    const trace_outermost = 8;

    /// Build a VM around `routine`, allocating a single top-level
    /// frame with `routine.slot_count` slots zero-initialized to nil.
    /// Caller owns the lifetime of `routine`; VM owns the stack,
    /// frames, and runtime arena and frees them in `deinit`.
    pub fn init(allocator: std.mem.Allocator, routine: *const Routine) !VM {
        // A host that runs the runtime on its own stack arms the guard
        // first (the CLI does); otherwise assume a main thread's
        // (docs/VM.md §13.1).
        stack_guard.armIfUnarmed(stack_guard.main_thread_budget);
        var stack: std.ArrayList(Value) = .empty;
        errdefer stack.deinit(allocator);
        try stack.appendNTimes(allocator, value_mod.nilValue(), routine.slot_count);

        var frames: std.ArrayList(Frame) = .empty;
        errdefer frames.deinit(allocator);
        try frames.append(allocator, .{
            .routine = routine,
            .base_slot = 0,
            .entry_stack_len = 0,
            .slot_count = routine.slot_count,
            .pc = 0,
        });

        const policy: GcPolicy = if (std.c.getenv("NEXIS_GC_STRESS") != null) .stress else .default;
        return .{
            .allocator = allocator,
            .stack = stack,
            .frames = frames,
            .runtime_arena = std.heap.ArenaAllocator.init(allocator),
            .gc_threshold = policy.threshold,
            .gc_growth_percent = policy.growth_percent,
            .gc_next_at = policy.threshold,
            .stack_high_water = stack.items.len,
            .frame_high_water = frames.items.len,
        };
    }

    pub fn deinit(self: *VM) void {
        // A binding frame still open (a sub-VM abandoned by an
        // error before its `finally` ran) is popped so the Vars,
        // which outlive this VM, keep no binding of its making.
        while (self.dyn_frames.items.len > 0) self.popBindings();
        self.dyn_saves.deinit(self.allocator);
        self.dyn_frames.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        // Free handler + finally stack backing storage. Both
        // contain POD entries.
        self.handlers.deinit(self.allocator);
        self.finally_stack.deinit(self.allocator);
        self.error_trace.deinit(self.allocator);
        // Interner owns hash maps allocated via self.allocator;
        // free explicitly.
        if (self.interner) |*it| it.deinit();
        // Registry owns its outer HashMap + per-ns
        // HashMaps (both via self.allocator). Free explicitly;
        // Namespace structs themselves are arena-backed.
        if (self.registry) |*reg| reg.deinit();
        if (self.namespace) |*ns| ns.deinit();
        // Close any still-open db Connections as a
        // safety net (callers should explicitly `db/close`).
        // Callback closes the emdb env AND destroys the
        // Connection struct allocated via self.allocator.
        if (self.db_close_callback) |close_fn| {
            for (self.db_connections.items) |conn_ptr| close_fn(conn_ptr);
        }
        self.db_connections.deinit(self.allocator);
        if (self.nextomic_close_callback) |close_fn| {
            for (self.nextomic_connections.items) |conn_ptr| close_fn(conn_ptr);
        }
        self.nextomic_connections.deinit(self.allocator);
        if (self.nextomic_query_state) |state| {
            if (self.nextomic_query_close) |close_fn| close_fn(state);
        }
        // Free record-registry storage (the entry
        // structs + their interned-name slices live in
        // self.allocator).
        for (self.record_registry.items) |entry| {
            self.allocator.free(entry.ns_name);
            self.allocator.free(entry.type_name);
            for (entry.field_names) |fname| self.allocator.free(fname);
            self.allocator.free(entry.field_names);
        }
        self.record_registry.deinit(self.allocator);
        // Free protocol-registry storage.
        for (self.protocol_registry.items) |*proto| {
            self.allocator.free(proto.ns_name);
            self.allocator.free(proto.name);
            for (proto.methods.items) |*method| {
                self.allocator.free(method.name);
                method.impls.deinit(self.allocator);
            }
            proto.methods.deinit(self.allocator);
        }
        self.protocol_registry.deinit(self.allocator);
        // The heap is backed by `allocator`: free every block still
        // live. A borrowed heap belongs to another VM.
        if (self.heap) |*h| h.deinit();
        self.runtime_arena.deinit();
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }

    /// The current namespace. If a NamespaceRegistry exists
    /// (via `ensureRegistry`), this returns `registry.current`
    /// (the namespace where `def`/`defn`/`defmacro` install).
    /// Otherwise it lazily initializes and returns the
    /// single-namespace slot used by ad-hoc test callers.
    pub fn ensureNamespace(self: *VM) *Namespace {
        if (self.registry) |*reg| return reg.current;
        if (self.namespace == null) {
            self.namespace = Namespace.init(self.allocator, self.runtime_arena.allocator());
        }
        return &self.namespace.?;
    }

    /// Lazy-initialize a NamespaceRegistry with the
    /// conventional `nexis.core` (auto-referred) and `user`
    /// (default current) namespaces.
    pub fn ensureRegistry(self: *VM) !*NamespaceRegistry {
        if (self.registry == null) {
            self.registry = NamespaceRegistry.initEmpty(
                self.allocator,
                self.runtime_arena.allocator(),
            );
            // Populate AFTER storage so back-pointers are stable.
            try self.registry.?.setupDefaults();
            // Make the VM heap reachable from the registry so
            // compile.zig's Form
            // lowering can allocate string-literal Values into
            // it via `namespace.registry.heap`.
            self.registry.?.heap = self.ensureHeap();
        }
        return &self.registry.?;
    }

    /// Lazy-initialize the shared Interner on first
    /// use. The Interner owns hash maps that need realloc/free,
    /// so it's backed by `self.allocator`, NOT runtime_arena.
    /// Symbol/keyword names are owned by the Interner (it
    /// dupes on intern). Interner.deinit in `VM.deinit` frees
    /// every interned name.
    pub fn ensureInterner(self: *VM) *intern_mod.Interner {
        if (self.borrowed_interner) |shared| return shared;
        if (self.interner == null) {
            self.interner = intern_mod.Interner.init(self.allocator);
        }
        return &self.interner.?;
    }

    /// The heap this VM allocates on: the borrowed one when set,
    /// else its own, initialized on first use. The Heap is just an
    /// allocator wrapper with a live-list; init is O(1) and there's
    /// no cost before the first use.
    pub fn ensureHeap(self: *VM) *heap_mod.Heap {
        if (self.borrowed_heap) |h| return h;
        if (self.heap == null) {
            self.heap = heap_mod.Heap.init(self.allocator);
        }
        return &self.heap.?;
    }

    /// A root scope starting at the top of the root stack.
    pub fn rootScope(self: *VM) RootScope {
        return .{ .vm = self, .base = self.roots.items.len };
    }

    /// `err`, with `error_detail` set to the formatted sentence (cut
    /// to nothing if it does not fit the buffer).
    fn fail(self: *VM, err: VmError, comptime fmt: []const u8, args: anytype) VmError {
        self.error_detail = std.fmt.bufPrint(&self.detail_buf, fmt, args) catch "";
        return err;
    }

    /// `ArityMismatch` for `name`, which takes `min` to `max`
    /// arguments (`max` null: no upper bound), called with `argc`.
    fn arityError(self: *VM, name: []const u8, min: usize, max: ?usize, argc: usize) VmError {
        const noun = if (min == 1) "argument" else "arguments";
        const e = VmError.ArityMismatch;
        if (max == null) return self.fail(e, "{s} takes at least {d} {s}, got {d}", .{ name, min, noun, argc });
        if (max.? == min) return self.fail(e, "{s} takes {d} {s}, got {d}", .{ name, min, noun, argc });
        return self.fail(e, "{s} takes {d} to {d} arguments, got {d}", .{ name, min, max.?, argc });
    }

    // -------------------------------------------------------------------------
    // The collector's host (VM.md §9, GC.md §3)
    // -------------------------------------------------------------------------

    /// Whether a cycle is due at this safe point: the VM collects,
    /// owns its heap, and the heap has allocated `gc_next_at` bytes
    /// since the last cycle.
    inline fn gcDue(self: *VM) bool {
        if (!self.gc_enabled or self.borrowed_heap != null) return false;
        const h = &(self.heap orelse return false);
        return h.allocated_since_collect >= self.gc_next_at;
    }

    /// Run one collection cycle over this VM's heap from this VM's
    /// roots, then size the next window. Callable from a safe point
    /// only: between two instructions, when every live value is in
    /// a slot, a frame, a Var, the root stack or one of the other
    /// roots `gcRoots` walks. Tests call it directly to force a
    /// cycle.
    pub fn collectGarbage(self: *VM) void {
        std.debug.assert(self.borrowed_heap == null);
        const heap = self.ensureHeap();
        var collector = gc_mod.Collector.init(heap);
        collector.host = .{ .ctx = @ptrCast(self), .roots = &gcRoots, .trace = &gcTrace };
        _ = collector.collect(&.{});
        self.gc_cycles += 1;
        // The query caches hold query values by heap identity
        // (docs/NEXTOMIC.md §5); a freed value's address may be
        // reused, so the caches empty with every cycle.
        if (self.nextomic_query_state) |state| {
            if (self.nextomic_query_clear) |clear| clear(state);
        }
        const by_growth = heap.live_bytes / 100 * self.gc_growth_percent;
        self.gc_next_at = @max(self.gc_threshold, by_growth);
    }

    /// Every root this VM holds (GC.md §3): the backing stack in
    /// full (a stale slot above a popped frame retains its value
    /// until the slot is reused, which is sound), every frame's
    /// closure, cells and routine constants, every Var of every
    /// namespace (root, metadata, thread binding), the saved
    /// bindings of every open `binding` frame, the root stack,
    /// pending `finally` throws, the unhandled throw, the halt
    /// result, and the protocol registry's implementations.
    fn gcRoots(ctx: *anyopaque, c: *gc_mod.Collector) void {
        const self: *VM = @ptrCast(@alignCast(ctx));
        for (self.stack.items) |v| c.markValue(v);
        for (self.frames.items) |*f| {
            c.markValue(f.closure);
            for (f.upvalues) |cell| c.mark(cellHeader(cell));
            markRoutineConsts(c, f.routine);
        }
        if (self.registry) |*reg| {
            var it = reg.map.valueIterator();
            while (it.next()) |ns| markNamespaceVars(c, ns.*);
        }
        if (self.namespace) |*ns| markNamespaceVars(c, ns);
        for (self.dyn_saves.items) |save| c.markValue(save.value);
        for (self.roots.items) |v| c.markValue(v);
        for (self.finally_stack.items) |cont| switch (cont.reason) {
            .throwing => |v| c.markValue(v),
            .normal => {},
        };
        if (self.unhandled_throw) |v| c.markValue(v);
        c.markValue(self.result);
        for (self.protocol_registry.items) |*proto| {
            for (proto.methods.items) |*method| {
                var impls = method.impls.valueIterator();
                while (impls.next()) |impl| c.markValue(impl.*);
                if (method.default_impl) |d| c.markValue(d);
            }
        }
    }

    fn markNamespaceVars(c: *gc_mod.Collector, ns: *const Namespace) void {
        var it = ns.vars.valueIterator();
        while (it.next()) |v| {
            c.markValue(v.*.root);
            c.markValue(v.*.meta);
            c.markValue(v.*.thread_value);
        }
    }

    /// The heap constants of `routine` and, recursively, of the
    /// routines in its pool: string and bignum literals live on the
    /// heap and a routine is reachable from every frame running it
    /// and every closure over it.
    fn markRoutineConsts(c: *gc_mod.Collector, routine: *const Routine) void {
        for (routine.consts) |k| switch (k) {
            .value => |v| c.markValue(v),
            .routine => |r| markRoutineConsts(c, r),
        };
    }

    /// Trace a closure (its cells and its routine's constants) or a
    /// cell (its value); the collector has marked `h` already.
    fn gcTrace(_: *anyopaque, h: *heap_mod.HeapHeader, c: *gc_mod.Collector) void {
        const k: value_mod.Kind = @enumFromInt(h.kind);
        switch (k) {
            .function => {
                const closure = heap_mod.Heap.bodyOf(Closure, h);
                for (closure.upvalues) |cell| c.mark(cellHeader(cell));
                markRoutineConsts(c, closure.routine);
            },
            .cell_internal => c.markValue(heap_mod.Heap.bodyOf(UpvalCell, h).value),
            else => unreachable,
        }
    }

    // -------------------------------------------------------------------------
    // Dynamic bindings (VM.md §6.5)
    // -------------------------------------------------------------------------

    /// Open a binding frame: every `(var, value)` pair rebinds a
    /// dynamic Var for the frame's extent, saving the binding it
    /// replaces. A Var that is not dynamic is `NotDynamic` and
    /// nothing is pushed. `binding` pairs the call with
    /// `popBindings` in a `finally`.
    pub fn pushBindings(self: *VM, vars: []const *Var, values: []const Value) VmError!void {
        std.debug.assert(vars.len == values.len);
        for (vars) |v| if (!v.dynamic) return VmError.NotDynamic;
        self.dyn_saves.ensureUnusedCapacity(self.allocator, vars.len) catch return VmError.OutOfMemory;
        self.dyn_frames.append(self.allocator, @intCast(self.dyn_saves.items.len)) catch return VmError.OutOfMemory;
        for (vars, values) |v, value| {
            self.dyn_saves.appendAssumeCapacity(.{ .v = v, .value = v.thread_value, .bound = v.thread_bound });
            v.thread_value = value;
            v.thread_bound = true;
        }
    }

    /// Close the innermost binding frame, restoring each Var's
    /// previous binding in reverse order. With no frame open it
    /// does nothing.
    pub fn popBindings(self: *VM) void {
        const start = self.dyn_frames.pop() orelse return;
        while (self.dyn_saves.items.len > start) {
            const save = self.dyn_saves.pop().?;
            save.v.thread_value = save.value;
            save.v.thread_bound = save.bound;
        }
    }

    /// Register a new record type
    /// in the per-VM record registry. Returns the dense `u32`
    /// type_id, or `RecordRedefinition` if a record type with
    /// the same `(ns, name)` already exists. Names are duped
    /// into `self.allocator` for stable ownership across the VM
    /// lifetime. PROTOCOLS.md §3.1.
    pub fn registerRecordType(
        self: *VM,
        ns_name: []const u8,
        type_name: []const u8,
        field_names: []const []const u8,
    ) !u32 {
        for (self.record_registry.items) |existing| {
            if (std.mem.eql(u8, existing.ns_name, ns_name) and
                std.mem.eql(u8, existing.type_name, type_name))
            {
                return error.RecordRedefinition;
            }
        }
        const new_id: u32 = @intCast(self.record_registry.items.len);
        const ns_dup = try self.allocator.dupe(u8, ns_name);
        errdefer self.allocator.free(ns_dup);
        const name_dup = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(name_dup);
        const fields_dup = try self.allocator.alloc([]const u8, field_names.len);
        errdefer self.allocator.free(fields_dup);
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) self.allocator.free(fields_dup[i]);
        }
        for (field_names, 0..) |fname, i| {
            fields_dup[i] = try self.allocator.dupe(u8, fname);
            initialized = i + 1;
        }
        try self.record_registry.append(self.allocator, .{
            .id = new_id,
            .ns_name = ns_dup,
            .type_name = name_dup,
            .field_names = fields_dup,
        });
        return new_id;
    }

    /// The type id of `nexis.core/Reduced`, the one-field record
    /// (`:val`) that `reduced` builds and `reduce` stops on.
    pub fn ensureReducedType(self: *VM) !u32 {
        if (self.reduced_type_id) |id| return id;
        const id = try self.registerRecordType("nexis.core", "Reduced", &.{"val"});
        self.reduced_type_id = id;
        return id;
    }

    /// Register a new protocol in
    /// the per-VM protocol registry. Method-spec is a slice of
    /// (interned-method-name-id, method-name-string) pairs;
    /// extend-protocol fills `impls` later. Returns the dense
    /// `u32` protocol id. Re-defining with the same `(ns, name)`
    /// raises `ProtocolRedefinition`.
    pub fn registerProtocol(
        self: *VM,
        ns_name: []const u8,
        protocol_name: []const u8,
        method_specs: []const ProtocolMethodSpec,
    ) !u32 {
        for (self.protocol_registry.items) |existing| {
            if (std.mem.eql(u8, existing.ns_name, ns_name) and
                std.mem.eql(u8, existing.name, protocol_name))
            {
                return error.ProtocolRedefinition;
            }
        }
        const new_id: u32 = @intCast(self.protocol_registry.items.len);
        const ns_dup = try self.allocator.dupe(u8, ns_name);
        errdefer self.allocator.free(ns_dup);
        const name_dup = try self.allocator.dupe(u8, protocol_name);
        errdefer self.allocator.free(name_dup);

        var methods: std.ArrayList(ProtocolMethod) = .empty;
        errdefer methods.deinit(self.allocator);
        for (method_specs) |spec| {
            const m_name = try self.allocator.dupe(u8, spec.name);
            errdefer self.allocator.free(m_name);
            try methods.append(self.allocator, .{
                .name_id = spec.name_id,
                .name = m_name,
            });
        }
        try self.protocol_registry.append(self.allocator, .{
            .id = new_id,
            .ns_name = ns_dup,
            .name = name_dup,
            .methods = methods,
        });
        return new_id;
    }

    pub fn protocolById(self: *VM, id: u32) ?*ProtocolEntry {
        if (id >= self.protocol_registry.items.len) return null;
        return &self.protocol_registry.items[id];
    }

    /// Register an impl `(protocol_id, method_name_id,
    /// dispatch_key) → impl`. Used by `extend-protocol` and by
    /// inline `defrecord` impls.
    pub fn extendProtocol(
        self: *VM,
        protocol_id: u32,
        method_name_id: u32,
        key: DispatchKey,
        impl: Value,
    ) !void {
        const proto = self.protocolById(protocol_id) orelse return error.NoProtocolMethod;
        for (proto.methods.items) |*method| {
            if (method.name_id == method_name_id) {
                try method.impls.put(self.allocator, key.canonical(), impl);
                return;
            }
        }
        return error.NoProtocolMethod;
    }

    /// Call the protocol fn `callee` with `args`: find the impl for
    /// the receiver's (`args[0]`) dispatch key, or the protocol's
    /// default, and call it. `NoProtocolImpl` when there is neither.
    pub fn dispatchProtocolMethod(
        self: *VM,
        callee: Value,
        args: []const Value,
    ) VmError!Value {
        std.debug.assert(callee.kind() == .protocol_fn);
        const protocol_id = protocol_mod.protocolFnProtocolId(callee);
        const method_name_id = protocol_mod.protocolFnMethodNameId(callee);
        const proto = self.protocolById(protocol_id) orelse return VmError.NoProtocolImpl;

        // Find the method by name_id.
        var method_ptr: ?*ProtocolMethod = null;
        for (proto.methods.items) |*m| {
            if (m.name_id == method_name_id) {
                method_ptr = m;
                break;
            }
        }
        const method = method_ptr orelse return VmError.NoProtocolMethod;
        if (args.len == 0) return self.arityError(method.name, 1, null, 0);

        // Look up impl by dispatch key (receiver is args[0]).
        const key = DispatchKey.ofValue(args[0]);
        const impl_v: Value = blk: {
            if (method.impls.get(key)) |impl| break :blk impl;
            if (method.default_impl) |dflt| break :blk dflt;
            return self.fail(VmError.NoProtocolImpl, "no impl of {s} for {s}", .{ method.name, kindPhrase(args[0].kind()) });
        };

        // Invoke. callValue handles closures, native_fns, etc.
        return try self.callValue(impl_v, args);
    }

    /// Allocate a closure block on the heap with room for
    /// `upvalue_count` cell pointers in its tail and return the
    /// `.function` Value naming it. The tail is the closure's
    /// `upvalues` array; the caller fills it before the Value can
    /// reach a slot. `asClosure()` is the matched accessor.
    pub fn allocClosure(self: *VM, routine: *const Routine, upvalue_count: usize) !Value {
        const heap = self.ensureHeap();
        const body_size = @sizeOf(Closure) + upvalue_count * @sizeOf(*UpvalCell);
        const h = try heap.alloc(.function, body_size);
        const body = heap_mod.Heap.bodyOf(Closure, h);
        const tail: [*]*UpvalCell = @ptrCast(@alignCast(@as([*]u8, @ptrCast(body)) + @sizeOf(Closure)));
        body.* = .{ .routine = routine, .upvalues = tail[0..upvalue_count] };
        return heap_mod.Heap.valueFromHeader(.function, h);
    }

    /// The closure body of a `.function` Value. Asserts the kind in
    /// safety builds; in release the cast is direct.
    pub fn asClosure(v: Value) *const Closure {
        std.debug.assert(v.kind() == .function);
        return heap_mod.Heap.bodyOf(Closure, heap_mod.Heap.asHeapHeader(v));
    }

    /// The writable cell-pointer tail of a closure block; only
    /// `closure:make` writes it, once, right after `allocClosure`.
    fn closureUpvaluesMut(v: Value) []*UpvalCell {
        const body = heap_mod.Heap.bodyOf(Closure, heap_mod.Heap.asHeapHeader(v));
        return @constCast(body.upvalues);
    }

    /// Invoke `closure_v` with `args` in a fresh sub-VM, `out_vm`,
    /// returning the result. The expander evaluates a macro this
    /// way: a sub-VM needs no save and restore of the calling VM's
    /// frames, handlers and finally stack. The closure's routine
    /// carries its `var_table` (pointers into the caller's
    /// namespaces) and its literal pool, so the sub-VM needs no
    /// namespace of its own; `interner`, when given, is shared so the
    /// ids in the arguments resolve.
    ///
    /// **Heap**: with `shared_heap` given, the sub-VM allocates on it
    /// (the calling VM's heap), so whatever the macro stores into a
    /// Var stays valid after the sub-VM is gone; without one the
    /// sub-VM's own heap holds its values until `deinit`. A sub-VM
    /// never collects: the values it reads through Vars and
    /// arguments live on heaps whose roots it cannot enumerate.
    ///
    /// **Lifetime**: on success the caller owns `out_vm` and must
    /// convert the result out of the sub-VM's heap (when none was
    /// shared) before calling its `deinit`. On failure `out_vm` is
    /// already released.
    pub fn evalClosure(
        allocator: std.mem.Allocator,
        closure_v: Value,
        args: []const Value,
        out_vm: *VM,
        interner: ?*intern_mod.Interner,
        shared_heap: ?*heap_mod.Heap,
    ) !Value {
        if (closure_v.kind() != .function) return error.NotCallable;
        out_vm.* = try VM.init(allocator, &idle_routine);
        errdefer out_vm.deinit();
        out_vm.borrowed_interner = interner;
        out_vm.borrowed_heap = shared_heap;
        out_vm.gc_enabled = false;
        return out_vm.callValue(closure_v, args);
    }

    /// Call `callee` with `args` from host code running inside the
    /// VM: how natives (`map`, `reduce`, `apply`, `swap!`, ...) call
    /// the functions they are given. Any callable works: a closure,
    /// a native, a protocol fn, a keyword, symbol or collection used
    /// as a lookup.
    ///
    /// **Args lifetime**: `args` is borrowed for the duration of the
    /// call and must not point into `vm.stack`.
    ///
    /// **Throw propagation**: if the callee throws and no handler
    /// inside the callee catches it, control transfers to a handler
    /// installed below the `callValue` entry point, and `callValue`
    /// returns `VmError.ControlTransferred`, an internal signal the
    /// calling native must propagate unchanged. The run loop beneath
    /// catches it and continues dispatch (frames and pc already
    /// adjusted by `unwindThrow`).
    ///
    /// **Rooting**: a closure receives `args` in its own slots; any
    /// other callee's `args` are pushed on the root stack for the
    /// call, so a native reached this way holds rooted arguments
    /// exactly as one reached by `call:call` holds them in the
    /// caller's slots. Values a native derives and keeps across a
    /// nested `callValue` are its own to root (`RootScope`; GC.md §3).
    pub fn callValue(self: *VM, callee: Value, args: []const Value) VmError!Value {
        // Every re-entry nests a native call and a run loop on the
        // native stack (§13.1).
        stack_guard.check() catch return VmError.StackOverflow;
        if (callee.kind() != .function) {
            const scope = self.rootScope();
            defer scope.release();
            try scope.pushAll(args);
            return self.callDirect(callee, args);
        }
        const base = self.stack.items.len;
        self.stack.appendSlice(self.allocator, args) catch return VmError.OutOfMemory;
        var result_cell = HostCallResult{};
        const depth = self.frames.items.len;
        self.enterClosure(callee, base, args.len, base, .{ .host_result = &result_cell }) catch |err| {
            self.stack.shrinkRetainingCapacity(base);
            return err;
        };
        try self.loop(depth);
        // Back at `depth` without a return: a throw went past us.
        if (!result_cell.done) return VmError.ControlTransferred;
        return result_cell.value;
    }

    /// Call `callee`, anything but a closure, with `args`, to
    /// completion on the native stack: a native (after its arity
    /// check), a protocol fn (dispatched on `args[0]`), or a lookup
    /// (`callLookup`). Anything else is `NotCallable`.
    fn callDirect(self: *VM, callee: Value, args: []const Value) VmError!Value {
        switch (callee.kind()) {
            .native_fn => {
                const native = asNativeFn(callee);
                if (args.len < native.min_arity or args.len > native.max_arity orelse args.len) {
                    const max: ?usize = if (native.max_arity) |m| m else null;
                    return self.arityError(native.name, native.min_arity, max, args.len);
                }
                return native.call(self, args);
            },
            .protocol_fn => return self.dispatchProtocolMethod(callee, args),
            else => {
                if (!isLookupCallable(callee.kind())) {
                    return self.fail(VmError.NotCallable, "{s} is not callable", .{kindPhrase(callee.kind())});
                }
                return callLookup(callee, args);
            },
        }
    }

    /// Where a closure frame's value goes when it returns.
    const Link = struct {
        return_dst: u12 = 0,
        return_pc: u32 = 0,
        host_result: ?*HostCallResult = null,
    };

    /// Enter `callee`, a closure whose `argc` arguments sit in
    /// `stack[base..base + argc]`, the one entry path for `call:call`,
    /// `callValue` and `evalClosure`: check the arity and the
    /// routine's shape, grow the stack over the callee's window, pack
    /// the arguments past the fixed ones into the rest list (nil when
    /// there are none, as in Clojure), nil every other slot the window
    /// and the arguments cover, and push the frame.
    /// `entry_stack_len` is the stack length its pop restores.
    fn enterClosure(self: *VM, callee: Value, base: usize, argc: usize, entry_stack_len: usize, link: Link) VmError!void {
        const closure = asClosure(callee);
        const routine = closure.routine;
        const fixed: usize = routine.fixed_arity;
        if (if (routine.variadic) argc < fixed else argc != fixed) {
            return self.arityError(routine.name, fixed, if (routine.variadic) null else fixed, argc);
        }
        if (closure.upvalues.len != routine.upvalue_count) return VmError.CaptureCountMismatch;
        // A variadic routine needs a slot for its rest parameter.
        if (routine.slot_count < fixed + @intFromBool(routine.variadic)) return VmError.BytecodeCorruption;

        const window_end = base + routine.slot_count;
        const args_end = base + argc;
        if (window_end > self.stack.items.len) {
            self.stack.appendNTimes(self.allocator, value_mod.nilValue(), window_end - self.stack.items.len) catch return VmError.OutOfMemory;
        }
        errdefer self.stack.shrinkRetainingCapacity(entry_stack_len);
        // The rest list is built while the excess arguments still
        // hold their values.
        var live_end = args_end;
        if (routine.variadic) {
            var rest = value_mod.nilValue();
            if (argc > fixed) {
                const heap = self.ensureHeap();
                rest = list_mod.empty(heap) catch return VmError.OutOfMemory;
                var j = args_end;
                while (j > base + fixed) {
                    j -= 1;
                    rest = list_mod.cons(heap, self.stack.items[j], rest) catch return VmError.OutOfMemory;
                }
            }
            self.stack.items[base + fixed] = rest;
            live_end = base + fixed + 1;
        }
        // Locals start nil, and so do excess argument slots past the
        // window: whatever they held is dead.
        @memset(self.stack.items[live_end..@max(args_end, window_end)], value_mod.nilValue());
        // An argument list longer than the window was appended by
        // `callValue` and ends at the window.
        const extent = @max(entry_stack_len, window_end);
        if (self.stack.items.len > extent) self.stack.shrinkRetainingCapacity(extent);

        try self.pushFrame(.{
            .routine = routine,
            .base_slot = @intCast(base),
            .entry_stack_len = @intCast(entry_stack_len),
            .slot_count = routine.slot_count,
            .return_dst = link.return_dst,
            .return_pc = link.return_pc,
            .upvalues = closure.upvalues,
            .closure = callee,
            .host_result = link.host_result,
        });
    }

    /// Run a compiled top-level `routine` to its `return` as a
    /// nested call: a frame above whatever is executing, on the
    /// stack above its slots, so the loader can run a required
    /// file's forms from inside a running program (a `require`
    /// reached through the compiler hooks) without retargeting the
    /// frame that is executing. The VM is left as it was found,
    /// idle or mid-execution; a throw the routine does not catch
    /// propagates as `UncaughtThrow` or, when the caller's handler
    /// (one installed beneath the nested frame) takes it,
    /// `ControlTransferred`, exactly as `callValue` reports it.
    pub fn runRoutine(self: *VM, routine: *const Routine) VmError!Value {
        stack_guard.check() catch return VmError.StackOverflow;
        if (routine.upvalue_count != 0) return VmError.CaptureCountMismatch;
        const base_slot: usize = self.stack.items.len;
        self.stack.appendNTimes(self.allocator, value_mod.nilValue(), routine.slot_count) catch return VmError.OutOfMemory;
        var result_cell = HostCallResult{};
        const initial_depth = self.frames.items.len;
        try self.pushFrame(.{
            .routine = routine,
            .base_slot = @intCast(base_slot),
            .entry_stack_len = @intCast(base_slot),
            .slot_count = routine.slot_count,
            .pc = 0,
            .host_result = &result_cell,
        });
        self.loop(initial_depth) catch |err| {
            self.recordErrorTrace(err);
            return err;
        };
        if (!result_cell.done) return VmError.ControlTransferred;
        return result_cell.value;
    }

    /// The fetch-and-dispatch loop, the only one: until the VM
    /// halts when `depth` is 0 (`run`), or until the frame chain is
    /// back to `depth` frames (`callValue`, `runRoutine`, which
    /// pushed the frame above it). A recoverable error becomes a
    /// keyword throw when a handler is in force
    /// (`handleRuntimeError`); any other error, or one with no
    /// handler, leaves the loop with the frames as they stood. When a
    /// throw unwinds past `depth` the loop ends without its frame's
    /// return, which the caller detects through its result cell.
    /// The `frame` pointer is scoped to one iteration: `step` may
    /// grow `frames` and invalidate it.
    fn loop(self: *VM, depth: usize) VmError!void {
        var check_gc = true;
        while (if (depth == 0) !self.halted else self.frames.items.len > depth) {
            if (check_gc and self.gcDue()) self.collectGarbage();
            const frame = self.currentFrame();
            if (frame.pc >= frame.routine.code.len) return VmError.BytecodeExhausted;
            const inst = frame.routine.code[frame.pc];
            frame.pc += 1;
            if (inst.kind == .extension) return VmError.UnimplementedOpcode;
            check_gc = self.step(frame, inst) catch |err| switch (err) {
                // A native's throw was caught below it: frames and pc
                // are already at the handler.
                VmError.ControlTransferred => true,
                else => blk: {
                    try self.handleRuntimeError(err);
                    break :blk true;
                },
            };
        }
    }

    /// Pack a `*Var` into a `Value` of kind `.var_`.
    /// Used by `var:store-var` (returns the Var object so
    /// `(def x 5)` evaluates to the Var, not the value 5) and
    /// by `var:var-object` (Clojure's `(var x)` reader form).
    /// The payload is the raw `*Var`, not a `*HeapHeader`: Vars
    /// are immortal arena objects the collector never sweeps.
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

    /// Allocate an UpvalCell block on the heap and return the
    /// VM-private `Value` of kind `.cell_internal` whose payload is
    /// the block header. When the compiler determines a binding is
    /// captured, it emits `closure:box-local s`, which boxes
    /// `slot[s]` and replaces it with the returned cell-value.
    pub fn allocCell(self: *VM, initial: Value, initialized: bool) !Value {
        const h = try self.ensureHeap().alloc(.cell_internal, @sizeOf(UpvalCell));
        heap_mod.Heap.bodyOf(UpvalCell, h).* = .{ .value = initial, .initialized = initialized };
        return Value{
            .tag = @as(u64, @intFromEnum(value_mod.Kind.cell_internal)),
            .payload = @intFromPtr(h),
        };
    }

    /// Decode a `.cell_internal` Value to its underlying
    /// `*UpvalCell`. Returns `ExpectedCell` if the Value's kind
    /// is anything else (the `:expected-cell` runtime trap).
    pub fn asCell(v: Value) VmError!*UpvalCell {
        if (v.kind() != value_mod.Kind.cell_internal) return VmError.ExpectedCell;
        return heap_mod.Heap.bodyOf(UpvalCell, @ptrFromInt(v.payload));
    }

    /// Pointer to the currently-executing frame. **Single-shot use
    /// only**: a `frames.append()` in any code path between fetch
    /// and use will invalidate this pointer. For multi-step access,
    /// read the relevant fields into locals or use `currentFrameIdx`.
    inline fn currentFrame(self: *VM) *Frame {
        // Empty frame stack is a VM invariant violation, not a
        // recoverable runtime condition.
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
    /// Two bounds checks, not one.
    /// - Logical (`slot_count`): catches bad bytecode.
    ///   call:call produces overlapping frame windows where
    ///   `stack.items.len > base_slot + slot_count` for the caller
    ///   even after the callee has been popped, so the logical
    ///   check is what defines a frame's visible slot range.
    /// - Physical (`stack.items.len`): catches corrupt VM/frame
    ///   state — a stale `slot_count` paired with a shrunken
    ///   stack would underrun otherwise.
    fn slotPtr(self: *VM, slot_index: u12) VmError!*Value {
        return self.slotPtrIn(self.currentFrame(), slot_index);
    }

    /// `slotPtr` against `frame`, the current frame a caller has
    /// already fetched: the hot handlers resolve every operand
    /// through one frame pointer instead of re-deriving it.
    inline fn slotPtrIn(self: *VM, frame: *const Frame, slot_index: u12) VmError!*Value {
        if (slot_index >= frame.slot_count) return VmError.OperandOutOfRange;
        const absolute: usize = @as(usize, frame.base_slot) + slot_index;
        if (absolute >= self.stack.items.len) return VmError.BytecodeCorruption;
        return &self.stack.items[absolute];
    }

    /// Resolve an operand to a `Value` (read side).
    ///
    /// For `.constant` operands the typed `Const` pool requires
    /// the entry to be `Const.value`. A `Const.routine` entry
    /// raises `InvalidOperandKind` (typed-pool enforcement) —
    /// `closure:make` is the only opcode that
    /// reads routine constants, and it does so via a dedicated
    /// path, not through generic `resolve()`.
    ///
    /// For `.upvalue` operands:
    /// `U` is the **cell-contents** operand kind. `resolve(u:N)`
    /// reads the current frame's `upvalues[N]` (a `*UpvalCell`),
    /// validates it's `initialized = true`, and returns the
    /// cell's value. Closure construction needs RAW cell pointers
    /// (not contents) and does NOT go through `resolve()` — it
    /// reads `frame.upvalues[u]` directly via a dedicated path
    /// in `execClosureMake`. Do not conflate the two.
    fn resolve(self: *VM, op: Operand) VmError!Value {
        return self.resolveIn(self.currentFrame(), op);
    }

    /// `resolve` against `frame`, the current frame.
    inline fn resolveIn(self: *VM, frame: *const Frame, op: Operand) VmError!Value {
        return switch (op.kind) {
            .slot => (try self.slotPtrIn(frame, op.index)).*,
            .constant => blk: {
                const consts = frame.routine.consts;
                if (op.index >= consts.len) return VmError.OperandOutOfRange;
                break :blk switch (consts[op.index]) {
                    .value => |v| v,
                    .routine => return VmError.InvalidOperandKind,
                };
            },
            .upvalue => blk: {
                if (op.index >= frame.upvalues.len) return VmError.UpvalueOutOfRange;
                const cell = frame.upvalues[op.index];
                if (!cell.initialized) return VmError.UninitializedCell;
                break :blk cell.value;
            },
            // V operand kind resolves through the
            // current routine's var_table to the Var's root
            // value. Unbound Vars (`!bound`) trap
            // `:unbound-var` — this is what makes forward
            // references work: compile time creates the Var,
            // runtime traps only if the Var is read before
            // any `def` has bound it.
            .var_ => blk: {
                const var_table = frame.routine.var_table;
                if (op.index >= var_table.len) return VmError.OperandOutOfRange;
                const v = var_table[op.index];
                // A dynamic Var under `binding` answers with the
                // binding in force; every other load is the root.
                if (v.thread_bound) break :blk v.thread_value;
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
    /// path. Other kinds split into two categories per VM.md §13:
    ///
    ///   - `.upvalue`: a recognized destination kind with no
    ///     store path (nothing writes through cells via U).
    ///     Returns `UnimplementedOpcode`.
    ///   - `.constant`, `.intern`, `.jump`, `.durable`: read-only
    ///     operand kinds; writing to them is invalid in this
    ///     opcode context, NOT "not wired." Surface
    ///     `InvalidOperandKind` per VM.md §13's `:invalid-operand-
    ///     kind` row.
    ///   - `.var_`: var writes go through `var:store-var` (a
    ///     dedicated opcode), not the generic store path. Generic
    ///     store with a `.var_` destination is a handler bug.
    ///     Surface `InvalidOperandKind`.
    ///   - `.unused`: invalid in any context with a destination
    ///     operand.
    fn store(self: *VM, op: Operand, v: Value) VmError!void {
        return self.storeIn(self.currentFrame(), op, v);
    }

    /// `store` against `frame`, the current frame.
    inline fn storeIn(self: *VM, frame: *const Frame, op: Operand, v: Value) VmError!void {
        switch (op.kind) {
            .slot => (try self.slotPtrIn(frame, op.index)).* = v,
            .upvalue => return VmError.UnimplementedOpcode,
            .constant, .var_, .intern, .jump, .durable, .unused => return VmError.InvalidOperandKind,
            _ => return VmError.BytecodeCorruption,
        }
    }

    const idle_code = [_]Inst{asm_.returnNil()};
    /// What the top frame points at between runs: a routine that
    /// returns nil and owns nothing, so the stack-local routine a
    /// runner passed to `retargetTop` is never referenced after its
    /// run, and a collection between runs marks nothing dead.
    pub const idle_routine: Routine = .{ .code = &idle_code, .consts = &.{}, .slot_count = 1, .name = "<idle>" };

    /// Point the top-level frame at `routine` and clear the halt
    /// flag so the next `run` executes it from its first
    /// instruction. The frame keeps its base slot; the backing
    /// stack is grown when the routine needs more slots than the
    /// previous one. This is how the REPL, the file runner, the
    /// loader and the tests run a sequence of compiled top-level
    /// forms on one VM whose namespaces, interner and runtime
    /// values persist between them.
    pub fn retargetTop(self: *VM, routine: *const Routine) VmError!void {
        // A failed run leaves its frames for the trace;
        // `resetAfterError` discards them before the next form.
        std.debug.assert(self.frames.items.len == 1);
        const top = &self.frames.items[0];
        top.routine = routine;
        top.pc = 0;
        top.slot_count = routine.slot_count;
        self.halted = false;
        if (self.stack.items.len < routine.slot_count) {
            self.stack.appendNTimes(self.allocator, value_mod.nilValue(), routine.slot_count - self.stack.items.len) catch return VmError.OutOfMemory;
        }
    }

    /// Run bytecode to completion (halt). Returns the VM's `result`
    /// slot. If bytecode exhausts without a `return`, returns
    /// `BytecodeExhausted`. Any error that leaves the run records
    /// the frame chain in `error_trace` first.
    pub fn run(self: *VM) VmError!Value {
        self.error_detail = "";
        self.loop(0) catch |err| {
            self.recordErrorTrace(err);
            return err;
        };
        self.frames.items[0].routine = &idle_routine;
        return self.result;
    }

    /// Where `err` left the run: every frame, innermost first, with
    /// the instruction it was executing. Every frame's `pc` is
    /// already past that instruction (the loop increments before it
    /// dispatches), so the failing index is `pc - 1`. Frames are
    /// intact here: an uncaught throw and an untranslated `VmError`
    /// both leave the chain as it was. A parked top frame (one
    /// resting on `idle_routine`) is not part of any run and is
    /// left out. A chain deeper than `trace_innermost +
    /// trace_outermost` keeps both ends and one marker frame, named
    /// for the number of frames between them.
    fn recordErrorTrace(self: *VM, err: VmError) void {
        self.error_trace.clearRetainingCapacity();
        self.traced_error = err;
        const frames = self.frames.items;
        const lowest: usize = if (frames[0].routine == &idle_routine) 1 else 0;
        const elided = (frames.len - lowest) -| (trace_innermost + trace_outermost);
        var i = frames.len;
        while (i > lowest) {
            i -= 1;
            if (elided > 0 and i == frames.len - 1 - trace_innermost) {
                const name = std.fmt.bufPrint(&self.trace_gap, "<{d} frames elided>", .{elided}) catch unreachable;
                self.error_trace.append(self.allocator, .{ .name = name, .pc = 0, .span = null, .source = null }) catch return;
                i -= elided - 1;
                continue;
            }
            const f = frames[i];
            const pc: u32 = if (f.pc > 0) f.pc - 1 else 0;
            self.error_trace.append(self.allocator, .{
                .name = f.routine.name,
                .pc = pc,
                .span = f.routine.spanAt(pc),
                .source = f.routine.source,
            }) catch return;
        }
    }

    /// Discard what a failed run left behind (the frames above the
    /// top-level one, handlers, pending finallys, the dynamic
    /// bindings a `binding` form had in force and the unhandled
    /// throw) so the next `retargetTop` starts from a clean VM. The
    /// error trace stays until the next failing run replaces it.
    pub fn resetAfterError(self: *VM) void {
        while (self.frames.items.len > 1) _ = self.popFrame();
        self.handlers.clearRetainingCapacity();
        self.finally_stack.clearRetainingCapacity();
        while (self.dyn_frames.items.len > 0) self.popBindings();
        self.unhandled_throw = null;
        self.frames.items[0].routine = &idle_routine;
    }

    /// Runtime error translation to a user-throwable Value.
    /// Recoverable errors (per VM.md
    /// §13 "Recoverable via try/catch" column) become keyword
    /// payloads routed through `unwindThrow`; non-recoverable
    /// errors (bytecode corruption, OOM, etc.) bubble back out
    /// unchanged.
    ///
    /// Translation: each recoverable VmError maps to a keyword
    /// like `:kind-mismatch` (a keyword, not a map).
    ///
    /// Note: throw machinery via unwindThrow may itself raise
    /// UncaughtThrow (if no handler catches the translated
    /// payload). That propagates back to the dispatch caller
    /// just like a user-level `(throw)`.
    fn handleRuntimeError(self: *VM, err: VmError) VmError!void {
        const kw_name = vmErrorToKeywordName(err) orelse return err;
        // Translate to a throwable Value only when a handler is
        // in force to take it; otherwise the raw VmError
        // propagates, so a program that does not opt into
        // try/catch sees the original error taxonomy.
        if (self.findThrowTarget() == null) return err;
        self.error_detail = "";
        const interner = self.ensureInterner();
        const id = interner.internKeyword(kw_name) catch return err;
        const payload = value_mod.fromKeywordId(id);
        try self.unwindThrow(payload);
    }

    /// One instruction, fetched from `frame`: the two-level switch
    /// of VM.md §8, on the group and then in each handler on the
    /// variant. The groups that never allocate and never push or pop
    /// a frame (`mov`, `cmp`, `jump`, `var`) run against `frame`
    /// directly; `math` allocates only on the heap and runs the same
    /// way; the others re-derive the frame. Returns whether the
    /// instruction could have allocated, which is when the next safe
    /// point has to test for a due collection: the heap's counter
    /// cannot move otherwise.
    inline fn step(self: *VM, frame: *Frame, inst: Inst) VmError!bool {
        switch (inst.groupOf()) {
            .mov => try self.execMov(frame, inst),
            .cmp => try self.execCmp(frame, inst),
            .jump => try self.execJump(frame, inst),
            .var_ => try self.execVar(frame, inst),
            .math => {
                try self.execMath(frame, inst);
                return true;
            },
            .call => {
                try self.execCall(inst);
                return true;
            },
            .closure => {
                try self.execClosure(inst);
                return true;
            },
            .coll => {
                try self.execColl(inst);
                return true;
            },
            .ctrl => {
                try self.execCtrl(inst);
                return true;
            },
            // Known groups with no implemented variants.
            .transient, .hash, .tx, .io, .simd => return VmError.UnimplementedOpcode,
            // Unrecognized group byte — bytecode corruption.
            _ => return VmError.BytecodeCorruption,
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Group `mov` (VM.md §10 #3)
    // -------------------------------------------------------------------------

    fn execMov(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        const variant: Mov = @enumFromInt(inst.variant);
        switch (variant) {
            .move => {
                // mov:move a b _      ;  slot[a] = resolve(b)
                const v = try self.resolveIn(frame, inst.b);
                try self.storeIn(frame, inst.a, v);
            },
            .load_const => {
                // mov:load-const a c _  ;  slot[a] = consts[c]
                const v = try self.resolveIn(frame, inst.b);
                try self.storeIn(frame, inst.a, v);
            },
            .load_nil => {
                try self.storeIn(frame, inst.a, value_mod.nilValue());
            },
            .load_true => {
                try self.storeIn(frame, inst.a, value_mod.fromBool(true));
            },
            .load_false => {
                try self.storeIn(frame, inst.a, value_mod.fromBool(false));
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
            // tailcall is unimplemented; `recur` compiles to a
            // jump instead.
            .tailcall => return VmError.UnimplementedOpcode,
            _ => return VmError.UnimplementedOpcode,
        }
    }

    /// `call:call A=call_base B=argc C=result_slot` — range-call
    /// ABI per VM.md §6. Caller has staged `slot[A] = callee` and
    /// `slot[A+1 .. A+1+argc] = args`. A closure callee gets a frame
    /// windowed over the arguments; its return lands in `slot[C]` and
    /// the caller resumes at the instruction following this one. Any
    /// other callee runs to completion here and its value lands in
    /// `slot[C]` at once.
    fn execCallCall(self: *VM, inst: Inst) VmError!void {
        // A and C are slot operands; B is a raw-index immediate
        // (§4.5).
        if (inst.a.kind != .slot or inst.c.kind != .slot) return VmError.InvalidOperandKind;
        const call_base: u32 = inst.a.index;
        const argc: u32 = inst.b.index;
        const result_dst: u12 = inst.c.index;

        const caller = self.currentFrame();
        if (call_base + 1 + argc > caller.slot_count) return VmError.CallBlockOutOfRange;
        if (result_dst >= caller.slot_count) return VmError.OperandOutOfRange;
        const callee = (try self.slotPtrIn(caller, @intCast(call_base))).*;
        const args_base: usize = @as(usize, caller.base_slot) + call_base + 1;
        if (args_base + argc > self.stack.items.len) return VmError.BytecodeCorruption;

        if (callee.kind() == .function) {
            // `caller.pc` is already past this instruction.
            return self.enterClosure(callee, args_base, argc, self.stack.items.len, .{
                .return_dst = result_dst,
                .return_pc = caller.pc,
            });
        }
        // The arguments are copied off the stack: the callee may
        // re-enter the VM and grow it. The slots keep them rooted.
        var buf: [8]Value = undefined;
        const args: []Value = if (argc <= buf.len)
            buf[0..argc]
        else
            self.allocator.alloc(Value, argc) catch return VmError.OutOfMemory;
        defer if (argc > buf.len) self.allocator.free(args);
        @memcpy(args, self.stack.items[args_base..][0..argc]);
        const result = try self.callDirect(callee, args);
        (try self.slotPtr(result_dst)).* = result;
    }

    /// Push `frame`. The caller has already grown the stack into
    /// the frame's window and recorded the length it found before
    /// doing so in `frame.entry_stack_len`; `popFrame` restores
    /// exactly that length.
    /// On failure the stack is restored to that length, as if the
    /// call had never started.
    fn pushFrame(self: *VM, frame: Frame) VmError!void {
        errdefer self.stack.shrinkRetainingCapacity(frame.entry_stack_len);
        if (self.frames.items.len >= self.max_frames) return VmError.StackOverflow;
        self.frames.append(self.allocator, frame) catch return VmError.OutOfMemory;
        if (self.frames.items.len > self.frame_high_water) {
            self.frame_high_water = self.frames.items.len;
        }
        if (self.stack.items.len > self.stack_high_water) {
            self.stack_high_water = self.stack.items.len;
        }
    }

    /// Pop the top frame and restore the stack to the length it
    /// recorded on entry. The top-level frame is never popped.
    fn popFrame(self: *VM) Frame {
        std.debug.assert(self.frames.items.len > 1);
        const frame = self.frames.pop().?;
        self.stack.shrinkRetainingCapacity(frame.entry_stack_len);
        return frame;
    }

    /// `call:call` on a keyword or collection (PLAN §8.7): `(:k m)`,
    /// `(m :k)`, `(s x)`, `(v i)` are lookups, which take at most a
    /// receiver and a default and never push a frame.
    fn execCallLookup(self: *VM, callee: Value, call_base: u32, argc: u32, result_dst: u12) VmError!void {
        if (argc > 2) return VmError.ArityMismatch;
        var args_buf: [2]Value = undefined;
        var i: u32 = 0;
        while (i < argc) : (i += 1) {
            args_buf[i] = (try self.slotPtr(@intCast(call_base + 1 + i))).*;
        }
        const result = try callLookup(callee, args_buf[0..argc]);
        if (result_dst >= self.currentFrame().slot_count) {
            return VmError.OperandOutOfRange;
        }
        (try self.slotPtr(result_dst)).* = result;
    }

    /// `call:return A=slot _ _` — return `slot[A]` from the current
    /// frame.
    fn execCallReturn(self: *VM, inst: Inst) VmError!void {
        // Read the return value while the callee frame is still
        // active; popping first would invalidate the slot.
        const return_value = try self.resolve(inst.a);
        return self.returnValue(return_value);
    }

    /// `call:return-nil` — return nil from the current frame.
    fn execCallReturnNil(self: *VM) VmError!void {
        return self.returnValue(value_mod.nilValue());
    }

    /// Complete the current frame with `return_value`. A frame
    /// pushed by `callValue` hands the value to its host result
    /// cell; the top-level frame halts the VM with it; any other
    /// frame is popped and the value lands in the caller's
    /// `return_dst` slot, where the caller resumes at `return_pc`.
    /// Frame metadata is validated before anything is mutated so
    /// a corrupt frame surfaces an error, not a half-popped VM.
    fn returnValue(self: *VM, return_value: Value) VmError!void {
        const callee = self.frames.items[self.frames.items.len - 1];
        if (callee.host_result) |hr| {
            hr.value = return_value;
            hr.done = true;
            _ = self.popFrame();
            return;
        }
        if (self.frames.items.len == 1) {
            self.result = return_value;
            self.halted = true;
            return;
        }
        const caller = self.frames.items[self.frames.items.len - 2];
        if (callee.return_dst >= caller.slot_count) return VmError.OperandOutOfRange;
        const absolute: usize = @as(usize, caller.base_slot) + callee.return_dst;
        _ = self.popFrame();
        self.stack.items[absolute] = return_value;
        self.frames.items[self.frames.items.len - 1].pc = callee.return_pc;
    }

    // -------------------------------------------------------------------------
    // Group `closure` (VM.md §10.4)
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
    /// Per VM.md §6.
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
        // allocCell touches the heap, not `vm.stack`, so `ptr` is
        // still valid.
        ptr.* = cell_value;
    }

    /// `closure:get-cell A=dst_slot B=cell_slot _` — read the
    /// contents of an UpvalCell whose pointer lives in slot[B];
    /// write to slot[A]. Used by same-frame reads of a boxed
    /// local.
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
    /// at slot[A]. Used by `letfn*` lowering and
    /// named `fn*` self-reference to allocate placeholder
    /// cells that subsequent `closure:make` instructions
    /// capture (raw cell pointer copied), and that
    /// `closure:init-cell` later fills in with the constructed
    /// closure value.
    ///
    /// Per VM.md §6. The cell starts with
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
    /// Used by `letfn*` and named `fn*` lowerings to
    /// finalize placeholder cells with the constructed closure
    /// value, after `closure:make` has constructed the closure
    /// (which captured the still-uninitialized cell).
    ///
    /// Per VM.md §6.
    ///
    /// Errors:
    ///   - ExpectedCell if slot[A] doesn't hold a cell pointer.
    ///   - InvalidCellState if the cell is already initialized
    ///     (double-init). Indicates compiler bug.
    fn execClosureInitCell(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        // Validate destination cell state BEFORE resolving B:
        // the destination contract is the
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
    /// per VM.md §6 (descriptor-based encoding).
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

        // Allocate the closure block, then fill its cell array
        // from the capture sources in descriptor order:
        //   .local_cell_slot(s): slot[s] must hold a cell-
        //     internal Value (boxed by prior closure:box-local).
        //   .inherited_upvalue(u): caller's frame.upvalues[u]
        //     is already a *UpvalCell pointer — copy directly.
        // Nothing allocates between the two steps, so the block is
        // complete before a safe point can see it.
        const closure_v = self.allocClosure(child_routine, desc.sources.len) catch
            return VmError.OutOfMemory;
        const upvalues = closureUpvaluesMut(closure_v);
        for (desc.sources, 0..) |source, i| {
            upvalues[i] = switch (source) {
                .local_cell_slot => |s| blk: {
                    const cell_v = (try self.slotPtr(s)).*;
                    // Must be a cell pointer (the
                    // `:expected-cell` trap). The compiler's
                    // capture pre-analysis guarantees this in
                    // well-formed bytecode; malformed bytecode
                    // (e.g., descriptor source referencing an
                    // un-boxed slot) traps here.
                    break :blk try VM.asCell(cell_v);
                },
                .inherited_upvalue => |u| blk: {
                    if (u >= frame.upvalues.len) return VmError.UpvalueOutOfRange;
                    // Direct raw-cell access — NOT via
                    // resolve(u), which would deref to
                    // cell-contents (raw-vs-contents
                    // distinction).
                    break :blk frame.upvalues[u];
                },
            };
        }

        try self.store(inst.c, closure_v);
    }

    // -------------------------------------------------------------------------
    // Group `math` (VM.md §10 #3 — PLAN §12.3 group 2)
    //
    // Every variant except `pow` goes through the numeric tower
    // (`numAdd` … `numAbs`), which handles fixnum, bignum and float
    // operands, promotion and contagion; a promoted result lives on
    // the VM's heap.
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Group `jump` (VM.md §10.5 — PLAN §12.3 group 0)
    //
    // Jump targets are absolute instruction indices within the
    // current routine's `code` array. Per VM.md §4.5, the jump
    // target operand is a "raw index" (kind ignored, index is
    // the data); the encoding convention is `Operand.jump(N)`
    // where N is the destination PC.
    // -------------------------------------------------------------------------

    fn execJump(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        const variant: Jump = @enumFromInt(inst.variant);
        switch (variant) {
            .jmp => {
                // jump:jmp A=target _ _   ; pc := A.index
                try applyJump(frame, inst.a);
            },
            .if_true => {
                // jump:if-true A=target B=test _   ; if truthy(B) pc := A.index
                const test_v = try self.resolveIn(frame, inst.b);
                if (test_v.isTruthy()) {
                    try applyJump(frame, inst.a);
                }
            },
            .if_false => {
                // jump:if-false A=target B=test _  ; if falsy(B) pc := A.index
                const test_v = try self.resolveIn(frame, inst.b);
                if (test_v.isFalsy()) {
                    try applyJump(frame, inst.a);
                }
            },
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// Apply a jump-target operand to the current frame's PC.
    ///
    /// Validates two things:
    ///   1. `target.kind` is `.jump`. Permissively accepting other
    ///      kinds (e.g., `.slot`) here would turn "stale placeholder
    ///      bytecode" into "infinite loop reading slot 0".
    ///      Requiring the `.jump` kind turns that class of
    ///      corruption into a
    ///      clean `InvalidOperandKind` at the type level.
    ///   2. The target PC is strictly within the routine's code
    ///      range. A target equal to `code.len` is illegal because
    ///      the next dispatch would surface BytecodeExhausted.
    fn applyJump(frame: *Frame, target: Operand) VmError!void {
        if (target.kind != .jump) return VmError.InvalidOperandKind;
        const pc: u32 = @intCast(target.index);
        if (pc >= frame.routine.code.len) return VmError.OperandOutOfRange;
        frame.pc = pc;
    }

    fn execMath(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        const variant: Math = @enumFromInt(inst.variant);
        // Resolve every source operand BEFORE storing so that
        // dst/src aliasing (e.g., math:add s0, s0, c0) is correct.
        const lhs = try self.resolveIn(frame, inst.b);
        const rhs = switch (variant) {
            .neg, .abs => value_mod.fromFixnum(0).?,
            else => try self.resolveIn(frame, inst.c),
        };
        const heap = self.ensureHeap();
        const result = switch (variant) {
            .add => numAdd(heap, lhs, rhs),
            .sub => numSub(heap, lhs, rhs),
            .mul => numMul(heap, lhs, rhs),
            .div => numDiv(heap, lhs, rhs),
            .idiv => numQuot(heap, lhs, rhs),
            .mod => numMod(heap, lhs, rhs),
            .neg => numNeg(heap, lhs),
            .abs => numAbs(heap, lhs),
            .pow => return VmError.UnimplementedOpcode,
            _ => return VmError.BytecodeCorruption,
        } catch |err| return self.numericError(err, switch (variant) {
            .add => "+",
            .sub, .neg => "-",
            .mul => "*",
            .div => "/",
            .idiv => "quot",
            .mod => "mod",
            else => "abs",
        }, lhs, rhs);
        try self.storeIn(frame, inst.a, result);
    }

    // -------------------------------------------------------------------------
    // Group `cmp` (VM.md §10 #1)
    // -------------------------------------------------------------------------

    fn execCmp(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        // cmp:<op> a b c   ;  slot[a] = bool(resolve(b) <op> resolve(c))
        const cmp = std.enums.fromInt(NumCmp, inst.variant) orelse return VmError.BytecodeCorruption;
        const lhs = try self.resolveIn(frame, inst.b);
        const rhs = try self.resolveIn(frame, inst.c);
        const holds_ = numCompare(cmp, lhs, rhs) catch |err| return self.numericError(err, switch (cmp) {
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .eq => "==",
        }, lhs, rhs);
        try self.storeIn(frame, inst.a, value_mod.fromBool(holds_));
    }

    /// `err` from the numeric operation `op` on `lhs` and `rhs`; a
    /// `KindMismatch` names the operand that is not a number.
    fn numericError(self: *VM, err: VmError, op: []const u8, lhs: Value, rhs: Value) VmError {
        if (err != VmError.KindMismatch) return err;
        const bad = if (isNumber(lhs)) rhs else lhs;
        return self.fail(err, "{s} expects numbers, got {s}", .{ op, kindPhrase(bad.kind()) });
    }

    // -------------------------------------------------------------------------
    // Group `var` (VM.md §10 #6)
    // -------------------------------------------------------------------------

    fn execVar(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        const variant: VarOp = @enumFromInt(inst.variant);
        switch (variant) {
            .load_var => try self.execVarLoadVar(frame, inst),
            .store_var => try self.execVarStoreVar(frame, inst),
            .var_object => try self.execVarVarObject(frame, inst),
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// `var:load-var A=dst_slot B=var(index) _` — read the Var
    /// at `routine.var_table[B.index]` and store its root value
    /// into `slot[A]`. Traps `:unbound-var` if the
    /// Var has never been bound by `def`.
    ///
    /// Semantically equivalent to `mov:move A=slot, B=var(idx)`
    /// (the V operand kind goes through the same resolve()
    /// path). The dedicated opcode exists for symmetry with
    /// `var:store-var` and for diagnostic clarity in
    /// disassembly.
    fn execVarLoadVar(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.b.kind != .var_) return VmError.InvalidOperandKind;
        const v = try self.resolveIn(frame, inst.b);
        try self.storeIn(frame, inst.a, v);
    }

    /// `var:store-var A=dst_slot B=var(index) C=value_op` —
    /// set `routine.var_table[B.index].root = resolve(C)`,
    /// mark `bound = true`, and write the Var object (a Value
    /// of kind `.var_`) into `slot[A]`.
    ///
    /// Returning the Var (not the value) matches Clojure's
    /// `def` semantics: `(def x 5)` evaluates to the Var
    /// `#'x`. Rebinding the same name updates the SAME Var in
    /// place (identity-stable), so existing closures that
    /// captured `x`'s Var continue to see the new value.
    fn execVarStoreVar(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.b.kind != .var_) return VmError.InvalidOperandKind;
        const var_table = frame.routine.var_table;
        if (inst.b.index >= var_table.len) return VmError.OperandOutOfRange;
        const target = var_table[inst.b.index];
        const new_value = try self.resolveIn(frame, inst.c);
        target.root = new_value;
        target.bound = true;
        try self.storeIn(frame, inst.a, VM.varToValue(target));
    }

    /// `var:var-object A=dst_slot B=var(index) _` — write the
    /// Var object itself (Value of kind `.var_`) into
    /// `slot[A]`. Does NOT trap on unbound; taking a reference
    /// to an unbound Var is legal (Clojure's `(var x)` /
    /// `#'x`).
    fn execVarVarObject(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.b.kind != .var_) return VmError.InvalidOperandKind;
        const var_table = frame.routine.var_table;
        if (inst.b.index >= var_table.len) return VmError.OperandOutOfRange;
        const target = var_table[inst.b.index];
        try self.storeIn(frame, inst.a, VM.varToValue(target));
    }

    // -------------------------------------------------------------
    // Group #7: `coll` — collection construction
    // -------------------------------------------------------------
    //
    // Operand convention (range ABI, mirrors call:call):
    //   A = slot   — first arg slot (must be `.slot` kind)
    //   B = raw    — argc (raw u12 immediate, kind ignored per §4.5)
    //   C = slot   — destination slot
    //
    // Every variant allocates via `self.ensureHeap()`. `Heap.alloc`
    // never collects (a cycle runs only at the safe point between
    // instructions, VM.md §9), so partial results need no rooting
    // during construction.

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
    /// right-to-left via `list_mod.cons`.
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

    /// `coll:concat A=arg_base B=argc C=dst` — each arg is a
    /// seqable (nil, list, vector, map, set); result is the list
    /// of every element left to right, so `~@` in syntax-quote
    /// splices whatever a seq function returns.
    /// Strategy: traverse each input, collect elements into a
    /// temp slice, then build the result right-to-left via cons.
    /// Avoids recursive append on singly-linked lists.
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
            const scratch = self.runtime_arena.allocator();
            switch (arg_val.kind()) {
                .nil => {},
                .list => {
                    var node = arg_val;
                    while (node.kind() == .list and !list_mod.isEmpty(node)) {
                        try elements.append(scratch, list_mod.head(node));
                        node = list_mod.tail(node);
                    }
                },
                .persistent_vector => {
                    const n = vector_mod.count(arg_val);
                    var j: usize = 0;
                    while (j < n) : (j += 1) try elements.append(scratch, vector_mod.nth(arg_val, j));
                },
                .persistent_map => {
                    var it = champ_mod.mapIter(arg_val);
                    while (it.next()) |e| {
                        const pair = [_]Value{ e.key, e.value };
                        const entry = vector_mod.fromSlice(heap, &pair) catch return VmError.OutOfMemory;
                        try elements.append(scratch, entry);
                    }
                },
                .persistent_set => {
                    var it = champ_mod.setIter(arg_val);
                    while (it.next()) |e| try elements.append(scratch, e);
                },
                else => return VmError.KindMismatch,
            }
        }

        // Second pass: build result right-to-left.
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
    /// `vector_mod.fromSlice`.
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

        const result = vector_mod.fromSlice(heap, elems.items) catch return VmError.OutOfMemory;
        try self.store(.{ .kind = .slot, .index = dst }, result);
    }

    /// `coll:map A=arg_base B=argc C=dst` — build a persistent
    /// map from argc slot values interpreted as flat k,v,k,v,...
    /// pairs. argc MUST be even. Iterates left-to-right calling
    /// `champ.mapAssoc`; later duplicate keys overwrite earlier
    /// (Clojure semantics).
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
    /// semantics).
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
    // Group #11: `ctrl` — try / catch / finally / throw
    // -------------------------------------------------------------
    //
    // Per VM.md §12. User-thrown values and the recoverable
    // VM-detected errors (translated by `translateRecoverable`)
    // are catchable; non-recoverable errors bubble out of `run`.

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
    /// C carries an absolute finally_pc as a `.jump` operand,
    /// OR is `.unused` for try forms
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
        try self.handlers.append(self.allocator, .{
            .kind = .try_,
            .frame_index = frame_index,
            .catch_pc = inst.a.index,
            .binding_slot = inst.b.index,
            .finally_pc = finally_pc,
            .finally_depth = self.finally_stack.items.len,
        });
    }

    /// `ctrl:try-exit A=post_pc B=unused C=unused` — pop the
    /// current handler (must belong to this frame).
    ///
    /// Jumps directly to post_pc, unless the popped handler had
    /// a finally: then push a
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

    /// `ctrl:finally-exit` — pop the topmost
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
    ///      handler).
    ///   2. Unwind frames above the handler's frame_index,
    ///      restoring the stack to the lowest popped frame's
    ///      entry length.
    ///   3. Store the thrown value into binding_slot.
    ///   4. Jump to catch_pc.
    ///
    /// If no `.try_` handler exists anywhere, stores the thrown
    /// value into `VM.unhandled_throw` and returns
    /// `VmError.UncaughtThrow`.
    fn execCtrlThrow(self: *VM, inst: Inst) VmError!void {
        const value = try self.resolve(inst.a);
        try self.unwindThrow(value);
    }

    /// Walk the handler stack top-down looking for the topmost
    /// handler that catches a throw:
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

    /// Throw `value` from native code exactly as `(throw value)`
    /// does from bytecode. When a handler catches it the frames
    /// and pc are already positioned at the handler and the result
    /// is `ControlTransferred`, which the caller returns unchanged
    /// so the run loop resumes there. With no handler anywhere the
    /// result is `UncaughtThrow` and `unhandled_throw` holds the
    /// value.
    pub fn throwValue(self: *VM, value: Value) VmError {
        self.unwindThrow(value) catch |err| return err;
        return VmError.ControlTransferred;
    }

    /// `throwValue` of the keyword named `name`.
    pub fn throwKeyword(self: *VM, name: []const u8) VmError {
        const id = self.ensureInterner().internKeyword(name) catch return VmError.OutOfMemory;
        return self.throwValue(value_mod.fromKeywordId(id));
    }

    /// Common throw-unwind logic. Used by `execCtrlThrow`,
    /// `throwValue` and by `finally-exit`'s `.throwing`
    /// continuation.
    fn unwindThrow(self: *VM, value: Value) VmError!void {
        const handler_idx = self.findThrowTarget() orelse {
            // No matching handler anywhere — uncaught.
            self.unhandled_throw = value;
            return VmError.UncaughtThrow;
        };
        const matched = self.handlers.items[handler_idx];

        // Discard any handlers above the matched one (cleanup
        // records from inner scopes that we passed over —
        // they're unreachable since their try is
        // unwinding through us).
        self.handlers.shrinkRetainingCapacity(handler_idx);
        // Likewise the continuations of finally bodies the throw
        // leaves mid-run, the one it was thrown from included.
        self.finally_stack.shrinkRetainingCapacity(matched.finally_depth);

        // Pop every frame above the handler's. A throw bypasses
        // the callers' return slots: the frames are only popped,
        // and each pop restores the stack length its frame
        // recorded on entry, so the lowest pop leaves the extent
        // the handler's frame set requires.
        while (self.frames.items.len - 1 > matched.frame_index) _ = self.popFrame();

        const frame = self.currentFrame();

        switch (matched.kind) {
            .try_ => {
                // Push a cleanup handler in place of the original
                // try.
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
                    .finally_depth = matched.finally_depth,
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

/// Stable taxonomy mapping recoverable VmError
/// variants to user-visible keyword names. Per VM.md §13
/// "Recoverable via try/catch" column.
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
        VmError.NotDynamic => "not-dynamic",
        VmError.NoThreadBinding => "no-thread-binding",
        VmError.ArithmeticOverflow => "arithmetic-overflow",
        VmError.DivideByZero => "divide-by-zero",
        VmError.IndexOutOfBounds => "index-out-of-bounds",
        VmError.DbError => "db-error",
        VmError.DbClosed => "db-closed",
        VmError.InvalidDurableRef => "invalid-durable-ref",
        VmError.CodecFailed => "codec-failed",
        VmError.TxClosed => "tx-closed",
        VmError.NotDerefable => "not-derefable",
        VmError.AtomReEntry => "atom-re-entry",
        VmError.Utf8Error => "utf8-error",
        VmError.InvalidArgument => "invalid-argument",
        VmError.IoError => "io-error",
        VmError.FileNotFound => "file-not-found",
        VmError.InvalidPath => "invalid-path",
        VmError.RecordRedefinition => "record-redefinition",
        VmError.NotARecord => "not-a-record",
        VmError.NoProtocolImpl => "no-protocol-impl",
        VmError.NoProtocolMethod => "no-protocol-method",
        VmError.ProtocolRedefinition => "protocol-redefinition",
        VmError.StackOverflow => "stack-overflow",
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
        VmError.ControlTransferred,
        => null,
    };
}

// =============================================================================
// Lookup (PLAN §6.5, §8.7)
//
// `get` and the invocable-as-lookup kinds share one lookup so that
// `(get m k)`, `(:k m)` and `(m :k)` cannot drift apart.
// =============================================================================

/// `(get coll key default)`. Maps and records look the key up,
/// sets return the element itself when present, vectors index by
/// fixnum, a lazy entity reads the attribute from its view, nil
/// yields the default. Any other receiver is a `KindMismatch`.
pub fn lookup(coll: Value, key: Value, default: Value) VmError!Value {
    return switch (coll.kind()) {
        .nil => default,
        .persistent_map => mapLookup(coll, key, default),
        .record => mapLookup(record_mod.fieldsOf(coll), key, default),
        // A lazy entity reads the attribute through the hook its box
        // carries (docs/NEXTOMIC.md §6); the hook returns only errors
        // of this set.
        .nextomic_entity => nextomic_handle.entityLookup(coll, key, default) catch |err| return @as(VmError, @errorCast(err)),
        .persistent_set => if (champ_mod.setContains(
            coll,
            key,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        )) key else default,
        .persistent_vector => blk: {
            if (key.kind() != .fixnum) break :blk default;
            const idx = key.asFixnum();
            if (idx < 0 or @as(usize, @intCast(idx)) >= vector_mod.count(coll)) break :blk default;
            break :blk vector_mod.nth(coll, @intCast(idx));
        },
        else => VmError.KindMismatch,
    };
}

fn mapLookup(m: Value, key: Value, default: Value) Value {
    return switch (champ_mod.mapGet(m, key, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
        .present => |v| v,
        .absent => default,
    };
}

/// How an error report names a value of kind `k`: as the language
/// presents it, the integer tower one kind.
pub fn kindPhrase(k: value_mod.Kind) []const u8 {
    return switch (k) {
        .nil => "nil",
        .false_, .true_ => "a boolean",
        .fixnum, .bignum => "an integer",
        .persistent_map => "a map",
        .persistent_set => "a set",
        .persistent_vector => "a vector",
        .function, .native_fn, .protocol_fn => "a function",
        .var_ => "a var",
        .error_ => "an error",
        .atom => "an atom",
        else => {
            inline for (@typeInfo(value_mod.Kind).@"enum".fields) |f| {
                if (@intFromEnum(k) == f.value) return "a " ++ f.name;
            }
            return "a value";
        },
    };
}

/// Kinds a `call:call` treats as a lookup rather than a function.
pub fn isLookupCallable(k: value_mod.Kind) bool {
    return switch (k) {
        .keyword, .symbol, .persistent_map, .persistent_set, .persistent_vector => true,
        else => false,
    };
}

/// Invoke a keyword or collection as a function.
///
///   (:k x)      → (get x :k)       nil when `x` is not a lookup target
///   (:k x d)    → (get x :k d)     a symbol, `('s x)`, alike
///   (m k), (m k d) → (get m k d)
///   (s x)       → (get s x)       sets take exactly one argument
///   (v i)       → (nth v i)       vectors take exactly one fixnum;
///                                 out of range is an error
///
/// Any other arity is `ArityMismatch` (PLAN §8.7).
pub fn callLookup(callee: Value, args: []const Value) VmError!Value {
    if (args.len < 1 or args.len > 2) return VmError.ArityMismatch;
    const default = if (args.len == 2) args[1] else value_mod.nilValue();
    return switch (callee.kind()) {
        .keyword, .symbol => switch (args[0].kind()) {
            .nil, .persistent_map, .record, .persistent_set, .persistent_vector, .nextomic_entity => lookup(args[0], callee, default),
            else => default,
        },
        .persistent_map => lookup(callee, args[0], default),
        .persistent_set => if (args.len == 1) lookup(callee, args[0], default) else VmError.ArityMismatch,
        .persistent_vector => blk: {
            if (args.len != 1) return VmError.ArityMismatch;
            if (args[0].kind() != .fixnum) return VmError.KindMismatch;
            const idx = args[0].asFixnum();
            if (idx < 0 or @as(usize, @intCast(idx)) >= vector_mod.count(callee)) return VmError.IndexOutOfBounds;
            break :blk vector_mod.nth(callee, @intCast(idx));
        },
        else => VmError.NotCallable,
    };
}

// =============================================================================
// Numeric tower (PLAN §8.3, SEMANTICS §2.2, BIGNUM.md §9)
//
// Three runtime number kinds take part in arithmetic: `fixnum`
// (i48), `bignum` and `float` (f64). Contagion follows Clojure: an
// operation with any float operand is carried out in f64 and yields
// a float; an operation on integers is exact, promoting to a bignum
// when a result leaves the i48 range and demoting to a fixnum when
// one fits (BIGNUM.md §1), so `=` and `hash` agree for every integer
// whatever its history. Two fixnums stay in i64 and touch the heap
// only on promotion. `/` on two integers yields an integer when the
// division is exact and a float otherwise (there are no rationals,
// PLAN §23 #10). Integer division by zero and `quot`/`rem`/`mod` by
// zero raise `DivideByZero`; float `/` by zero follows IEEE and
// yields an infinity or NaN.
//
// These are the single implementation behind the `math:*` and
// `cmp:*` opcodes and the arithmetic natives in stdlib.zig. The heap
// is the VM's (`ensureHeap`), where a promoted result lives.
// =============================================================================

/// Any operand kind arithmetic accepts.
pub fn isNumber(v: value_mod.Value) bool {
    return v.isFixnum() or v.isFloat() or v.kind() == .bignum;
}

/// Any member of the integer tower.
pub fn isInteger(v: value_mod.Value) bool {
    return bignum_mod.isInteger(v);
}

/// Widen a number to f64 for a contagious operation.
fn toFloat(v: value_mod.Value) VmError!f64 {
    return switch (v.kind()) {
        .fixnum => @floatFromInt(v.asFixnum()),
        .float => v.asFloat(),
        .bignum => bignum_mod.toF64(v),
        else => VmError.KindMismatch,
    };
}

/// An i64 result of a fixnum × fixnum operation in canonical form:
/// a fixnum when it fits, a bignum otherwise.
fn integerResult(heap: *heap_mod.Heap, n: i64) VmError!value_mod.Value {
    return value_mod.fromFixnum(n) orelse (bignum_mod.fromI64(heap, n) catch VmError.OutOfMemory);
}

fn isZero(v: value_mod.Value) bool {
    return (v.isFixnum() and v.asFixnum() == 0) or (v.isFloat() and v.asFloat() == 0);
}

const IntOp = enum { add, sub, mul };

/// One contagious binary operation. Two fixnums stay in i64 (a
/// product of two i48 values fits i96, so i128 is exact) and the
/// result is canonicalized; any float operand widens both sides to
/// f64; any other pair of integers goes through bignum arithmetic.
fn arith(comptime op: IntOp, heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    if (a.isFixnum() and b.isFixnum()) {
        const x = a.asFixnum();
        const y = b.asFixnum();
        return switch (op) {
            .add => integerResult(heap, x + y),
            .sub => integerResult(heap, x - y),
            .mul => blk: {
                const p = @as(i128, x) * @as(i128, y);
                if (p >= value_mod.fixnum_min and p <= value_mod.fixnum_max) break :blk value_mod.fromFixnum(@intCast(p)).?;
                break :blk bignum_mod.fromI128(heap, p) catch VmError.OutOfMemory;
            },
        };
    }
    if (a.isFloat() or b.isFloat()) {
        const x = try toFloat(a);
        const y = try toFloat(b);
        return value_mod.fromFloat(switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
        });
    }
    if (!isInteger(a) or !isInteger(b)) return VmError.KindMismatch;
    return (switch (op) {
        .add => bignum_mod.add(heap, a, b),
        .sub => bignum_mod.sub(heap, a, b),
        .mul => bignum_mod.mul(heap, a, b),
    }) catch VmError.OutOfMemory;
}

const DivOp = enum { quot, rem, mod };

/// The division family: a zero divisor of either kind raises before
/// the operation is chosen. `quot` truncates; `rem` takes the
/// dividend's sign; `mod` is floored and takes the divisor's sign.
fn divLike(comptime op: DivOp, heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    if (isZero(b)) return VmError.DivideByZero;
    if (a.isFixnum() and b.isFixnum()) {
        const x = a.asFixnum();
        const y = b.asFixnum();
        // Only `(quot fixnum_min -1)` leaves the fixnum range.
        return integerResult(heap, switch (op) {
            .quot => @divTrunc(x, y),
            .rem => @rem(x, y),
            .mod => @mod(x, y),
        });
    }
    if (a.isFloat() or b.isFloat()) {
        const x = try toFloat(a);
        const y = try toFloat(b);
        return value_mod.fromFloat(switch (op) {
            .quot => @trunc(x / y),
            .rem => @rem(x, y),
            .mod => blk: {
                const r = @rem(x, y);
                break :blk if (r != 0 and (r < 0) != (y < 0)) r + y else r;
            },
        });
    }
    if (!isInteger(a) or !isInteger(b)) return VmError.KindMismatch;
    return (switch (op) {
        .quot => bignum_mod.quot(heap, a, b),
        .rem => bignum_mod.rem(heap, a, b),
        .mod => bignum_mod.mod(heap, a, b),
    }) catch VmError.OutOfMemory;
}

pub fn numAdd(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return arith(.add, heap, a, b);
}

pub fn numSub(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return arith(.sub, heap, a, b);
}

pub fn numMul(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return arith(.mul, heap, a, b);
}

/// `/`: an exact integer quotient stays an integer, anything else
/// is f64.
pub fn numDiv(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    if (a.isFixnum() and b.isFixnum()) {
        const x = a.asFixnum();
        const y = b.asFixnum();
        if (y == 0) return VmError.DivideByZero;
        if (@rem(x, y) == 0) return integerResult(heap, @divTrunc(x, y));
        return value_mod.fromFloat(@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(y)));
    }
    if (a.isFloat() or b.isFloat()) return value_mod.fromFloat(try toFloat(a) / try toFloat(b));
    if (!isInteger(a) or !isInteger(b)) return VmError.KindMismatch;
    if (isZero(b)) return VmError.DivideByZero;
    const exact = bignum_mod.quotExact(heap, a, b) catch return VmError.OutOfMemory;
    return exact orelse value_mod.fromFloat(bignum_mod.toF64(a) / bignum_mod.toF64(b));
}

/// `quot`: truncated division. A zero divisor of either kind raises.
pub fn numQuot(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return divLike(.quot, heap, a, b);
}

/// `rem`: remainder of truncated division, sign of the dividend.
pub fn numRem(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return divLike(.rem, heap, a, b);
}

/// `mod`: remainder of floored division, sign of the divisor.
pub fn numMod(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return divLike(.mod, heap, a, b);
}

pub fn numNeg(heap: *heap_mod.Heap, a: value_mod.Value) VmError!value_mod.Value {
    return switch (a.kind()) {
        .fixnum => integerResult(heap, -a.asFixnum()),
        .float => value_mod.fromFloat(-a.asFloat()),
        .bignum => bignum_mod.neg(heap, a) catch VmError.OutOfMemory,
        else => VmError.KindMismatch,
    };
}

pub fn numAbs(heap: *heap_mod.Heap, a: value_mod.Value) VmError!value_mod.Value {
    return switch (a.kind()) {
        .fixnum => integerResult(heap, @intCast(@abs(a.asFixnum()))),
        .float => value_mod.fromFloat(@abs(a.asFloat())),
        .bignum => bignum_mod.abs(heap, a) catch VmError.OutOfMemory,
        else => VmError.KindMismatch,
    };
}

/// The comparison predicates of the tower. The variants share
/// their values with the `cmp` opcode group so `execCmp` needs no
/// mapping.
pub const NumCmp = enum(u6) { lt, lte, gt, gte, eq };

comptime {
    for (std.meta.tags(NumCmp)) |tag| {
        const op: Cmp = @enumFromInt(@intFromEnum(tag));
        std.debug.assert(std.mem.startsWith(u8, @tagName(op), @tagName(tag)));
    }
}

/// Ordered comparison across the tower. Two integers compare
/// exactly at any size; any float operand widens both sides to f64,
/// so `(< 1 1.5)` holds and `(== 1 1.0)` holds. NaN compares false
/// under every predicate, as IEEE specifies.
pub fn numCompare(cmp: NumCmp, a: value_mod.Value, b: value_mod.Value) VmError!bool {
    if (a.isFixnum() and b.isFixnum()) return ordered(i64, cmp, a.asFixnum(), b.asFixnum());
    if (a.isFloat() or b.isFloat()) return ordered(f64, cmp, try toFloat(a), try toFloat(b));
    return holds(cmp, try integerOrder(a, b));
}

fn ordered(comptime T: type, cmp: NumCmp, x: T, y: T) bool {
    return switch (cmp) {
        .lt => x < y,
        .lte => x <= y,
        .gt => x > y,
        .gte => x >= y,
        .eq => x == y,
    };
}

fn holds(cmp: NumCmp, ord: std.math.Order) bool {
    return switch (cmp) {
        .lt => ord == .lt,
        .lte => ord != .gt,
        .gt => ord == .gt,
        .gte => ord != .lt,
        .eq => ord == .eq,
    };
}

/// Exact order of two integers of any size.
fn integerOrder(a: value_mod.Value, b: value_mod.Value) VmError!std.math.Order {
    if (!isInteger(a) or !isInteger(b)) return VmError.KindMismatch;
    if (a.isFixnum() and b.isFixnum()) return std.math.order(a.asFixnum(), b.asFixnum());
    return bignum_mod.compare(a, b);
}

/// Sign tests shared by `zero?`, `pos?` and `neg?`: the order of
/// the number against zero, or `null` for NaN, which is neither
/// positive, negative nor zero (Clojure's `isZero`, `isPos` and
/// `isNeg` are all false on it). Negative zero is zero.
pub fn numSign(a: value_mod.Value) VmError!?std.math.Order {
    return switch (a.kind()) {
        .fixnum => std.math.order(a.asFixnum(), 0),
        .bignum => if (bignum_mod.isNegative(a)) .lt else .gt,
        .float => blk: {
            const f = a.asFloat();
            if (f > 0) break :blk .gt;
            if (f < 0) break :blk .lt;
            if (f == 0) break :blk .eq;
            break :blk null;
        },
        else => VmError.KindMismatch,
    };
}

/// `even?` / `odd?`: integers only, as in Clojure.
pub fn numEven(a: value_mod.Value) VmError!bool {
    if (!isInteger(a)) return VmError.KindMismatch;
    return bignum_mod.isEven(a);
}

/// `long`: a number as an integer. An integer is itself; a finite
/// float is its integer part (toward zero), a bignum when that is
/// wide; NaN and the infinities have no integer and raise
/// `InvalidArgument`.
pub fn numLong(heap: *heap_mod.Heap, a: value_mod.Value) VmError!value_mod.Value {
    if (isInteger(a)) return a;
    if (!a.isFloat()) return VmError.KindMismatch;
    const converted = bignum_mod.fromF64(heap, a.asFloat()) catch return VmError.OutOfMemory;
    return converted orelse VmError.InvalidArgument;
}

/// `double`: a number as an f64, a bignum through its nearest double.
pub fn numDouble(a: value_mod.Value) VmError!value_mod.Value {
    return value_mod.fromFloat(try toFloat(a));
}

/// `max`/`min` over two operands: the winning operand itself, of
/// its own kind (`(max 2 1.0)` is 2); on a tie the second, as
/// Clojure's `(if (> x y) x y)`; NaN wins.
pub fn numExtremum(want_max: bool, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    if (a.isFloat() or b.isFloat()) {
        const x = try toFloat(a);
        const y = try toFloat(b);
        if (std.math.isNan(x)) return a;
        if (std.math.isNan(y)) return b;
        return if (if (want_max) x > y else x < y) a else b;
    }
    const ord = try integerOrder(a, b);
    return if (ord == (if (want_max) std.math.Order.gt else std.math.Order.lt)) a else b;
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

/// Encoding helpers. Every opcode the compiler emits has a
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
    /// `b` and `c` may be any kind that `resolve` accepts.
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
    /// Non-numeric operands trap :kind-mismatch.
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
    /// Traps :unbound-var if the Var has never been bound by
    /// `def`.
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
    ///   slot[dst] := Var-object.
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
    /// (does NOT trap on unbound). Clojure's
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
    /// argc consecutive slots starting at arg_base.
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
    /// argc list values starting at arg_base.
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
    /// handler with finally.
    pub fn tryEnterFinally(catch_pc: u12, binding_slot: u12, finally_pc: u12) Inst {
        return Inst.primary(
            .ctrl,
            CtrlOp.try_enter,
            Operand.jump(catch_pc),
            Operand.slot(binding_slot),
            Operand.jump(finally_pc),
        );
    }

    /// ctrl:try-exit post_pc _ _   ; pop handler, jump to
    /// post_pc; if the popped handler has finally, push
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
    /// unwind).
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
    /// Operand kind may be slot, constant, or var.
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
    /// built from argc consecutive slot values.
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
    /// from argc/2 k,v pairs (argc MUST be even).
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
    /// from argc slot values (duplicates collapse).
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
    /// for forward jumps whose target wasn't known at emit time.
    pub fn patchJumpTarget(inst: *Inst, target_pc: u12) void {
        inst.a = Operand.jump(target_pc);
    }

    /// `closure:make A=prototype_const B=cap_desc_imm C=result_slot`
    /// per VM.md §6 (descriptor-based shape).
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
    /// range-call ABI. Caller has already
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
    /// Used by `compileSymbol` for upvalue reads:
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
    /// pointer. Emission timing per COMPILER.md §6.1.
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
    /// UpvalCell, store cell pointer at slot[A]. Placeholder
    /// cell for letfn* / named fn*.
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
    /// initialized=true. letfn* / named fn* finalize.
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

test "VM frames: stack and frames structures initialized correctly" {
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

test "VM frames: slotPtr through backing stack with base_slot indirection" {
    // Verify that slot access goes through base_slot, not a
    // per-frame slice. With base_slot = 0 this is functionally
    // equivalent to direct slice access; the test exists to
    // pin the indirection so an "optimization" that stores a
    // slice can't bypass it silently.
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

test "VM frames: slotPtr out-of-range surfaces OperandOutOfRange" {
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

// ---- coll group tests ---------------------------

test "VM coll: coll:list with argc=0 builds the empty list" {
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

test "VM coll: coll:list with 3 fixnums builds [1 2 3]" {
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

test "VM coll: coll:concat with argc=0 builds the empty list" {
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

test "VM coll: coll:concat ([1 2] [3]) → [1 2 3]" {
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

test "VM coll: coll:concat on a non-seqable arg traps KindMismatch" {
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

// ---- ctrl group tests ---------------------------

test "VM ctrl: try-enter pushes handler, try-exit pops it" {
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

test "VM ctrl: throw caught by current frame's try handler" {
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

test "VM ctrl: throw with no handler raises UncaughtThrow" {
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
    // Payload stored for diagnostics.
    try testing.expect(vm.unhandled_throw != null);
    try testing.expectEqual(@as(i64, 13), vm.unhandled_throw.?.asFixnum());
}

test "VM ctrl: throw inside catch body NOT re-caught by same handler" {
    // (try (throw :a) (catch any e (throw :b)))
    // The inner throw must NOT be caught by the same handler;
    // it should propagate as UncaughtThrow (no outer try here).
    // This is the "classic trap": the throw-handler replaces
    // the try with cleanup so the catch body's own throw
    // bypasses the same handler.
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
    // transient group (8) with variant 0 — a known group with no
    // implemented variants. Invariant: this test must name a
    // group the dispatcher does not implement (transient, hash,
    // tx, io or simd).
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
    const res = vm.run();
    try testing.expectError(VmError.UnimplementedOpcode, res);
}

test "VM: unrecognized group (bit-pattern 60) returns BytecodeCorruption" {
    // Build a raw Inst with a group number outside the allocated
    // space (60, well above the 14 groups). The non-exhaustive
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
    // The exact bytecode the compiler emits for `(+ 1 2)`:
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

test "VM math:add: a sum that leaves i48 promotes to a bignum" {
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
    const res = try vm.run();
    try testing.expect(res.kind() == .bignum);
    try testing.expect(!bignum_mod.isNegative(res));
    try testing.expectEqual(@as(u64, 1) << 47, bignum_mod.limbs(res)[0]);
}

test "VM math:add: a float operand makes the result a float" {
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
    const result = try vm.run();
    try testing.expect(result.isFloat());
    try testing.expectEqual(@as(f64, 3.5), result.asFloat());
}

test "VM math:add: a non-numeric operand surfaces KindMismatch" {
    const consts = [_]Const{
        cval(value_mod.fromBool(true)),
        cval(value_mod.fromFixnum(2).?),
    };
    var code = [_]Inst{
        asm_.mathAdd(0, Operand.constant(0), Operand.constant(1)),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "(+ true 2)");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.KindMismatch, res);
}

// ---- numeric tower ----

fn fx(n: i64) value_mod.Value {
    return value_mod.fromFixnum(n).?;
}

fn fl(f: f64) value_mod.Value {
    return value_mod.fromFloat(f);
}

fn expectDecimal(expected: []const u8, v: value_mod.Value) !void {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();
    try bignum_mod.formatDecimal(v, &w.writer);
    try testing.expectEqualStrings(expected, w.written());
}

test "numeric tower: contagion, exact division and integer results" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const h = &heap;
    try testing.expectEqual(@as(i64, 7), (try numAdd(h, fx(3), fx(4))).asFixnum());
    try testing.expectEqual(@as(f64, 7.5), (try numAdd(h, fx(3), fl(4.5))).asFloat());
    try testing.expectEqual(@as(f64, 7.5), (try numAdd(h, fl(3.5), fx(4))).asFloat());
    try testing.expectEqual(@as(f64, -1.0), (try numSub(h, fl(3.0), fx(4))).asFloat());
    try testing.expectEqual(@as(i64, 12), (try numMul(h, fx(3), fx(4))).asFixnum());
    try testing.expectEqual(@as(f64, 1.5), (try numMul(h, fl(0.5), fx(3))).asFloat());
    // `/` of two fixnums: exact stays fixnum, inexact is f64.
    try testing.expectEqual(@as(i64, 2), (try numDiv(h, fx(6), fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, -2), (try numDiv(h, fx(6), fx(-3))).asFixnum());
    try testing.expectEqual(@as(f64, 2.5), (try numDiv(h, fx(5), fx(2))).asFloat());
    try testing.expectEqual(@as(f64, 2.5), (try numDiv(h, fl(5.0), fx(2))).asFloat());
    // quot / rem / mod: truncated vs floored.
    try testing.expectEqual(@as(i64, -2), (try numQuot(h, fx(-7), fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, -1), (try numRem(h, fx(-7), fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, 2), (try numMod(h, fx(-7), fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, -2), (try numMod(h, fx(7), fx(-3))).asFixnum());
    try testing.expectEqual(@as(f64, -2.0), (try numQuot(h, fl(-7.0), fx(3))).asFloat());
    try testing.expectEqual(@as(f64, -1.0), (try numRem(h, fl(-7.0), fx(3))).asFloat());
    try testing.expectEqual(@as(f64, 2.0), (try numMod(h, fl(-7.0), fx(3))).asFloat());
    try testing.expectEqual(@as(f64, -0.5), (try numMod(h, fl(7.5), fx(-2))).asFloat());
    try testing.expectEqual(@as(f64, -1.0), (try numMod(h, fx(5), fl(-1.5))).asFloat());
    try testing.expectEqual(@as(f64, 0.0), (try numMod(h, fl(6.0), fx(-2))).asFloat());
    try testing.expectEqual(@as(i64, -3), (try numNeg(h, fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, 3), (try numAbs(h, fx(-3))).asFixnum());
    try testing.expectEqual(@as(f64, 3.5), (try numAbs(h, fl(-3.5))).asFloat());
    // Nothing above left the fixnum range, so nothing touched the heap.
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "numeric tower: results that leave i48 promote and results that fit demote" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const h = &heap;
    try expectDecimal("140737488355328", try numAdd(h, fx(value_mod.fixnum_max), fx(1)));
    try expectDecimal("-140737488355329", try numSub(h, fx(value_mod.fixnum_min), fx(1)));
    try expectDecimal("1152921504606846976", try numMul(h, fx(1 << 30), fx(1 << 30)));
    try expectDecimal("19807040628565802923409276929", try numMul(h, fx(value_mod.fixnum_max), fx(value_mod.fixnum_max)));
    try expectDecimal("140737488355328", try numNeg(h, fx(value_mod.fixnum_min)));
    try expectDecimal("140737488355328", try numAbs(h, fx(value_mod.fixnum_min)));
    try expectDecimal("140737488355328", try numDiv(h, fx(value_mod.fixnum_min), fx(-1)));
    try expectDecimal("140737488355328", try numQuot(h, fx(value_mod.fixnum_min), fx(-1)));
    // Back across the boundary: the reverse step is a fixnum again.
    const over = try numAdd(h, fx(value_mod.fixnum_max), fx(1));
    try testing.expect(over.kind() == .bignum);
    const back = try numSub(h, over, fx(1));
    try testing.expect(back.kind() == .fixnum);
    try testing.expectEqual(value_mod.fixnum_max, back.asFixnum());
    // Bignum × bignum, and the division family on bignums.
    const sq = try numMul(h, over, over);
    try expectDecimal("19807040628566084398385987584", sq);
    try testing.expect(dispatch_mod.equal(try numDiv(h, sq, over), over));
    try testing.expect((try numDiv(h, sq, fx(3))).isFloat());
    try testing.expectEqual(@as(i64, 0), (try numRem(h, sq, over)).asFixnum());
    try testing.expectEqual(@as(i64, 1), (try numRem(h, try numAdd(h, sq, fx(1)), over)).asFixnum());
    try testing.expect(dispatch_mod.equal(try numQuot(h, try numAdd(h, sq, fx(1)), over), over));
    const neg_sq = try numNeg(h, sq);
    try testing.expectEqual(@as(i64, -1), (try numRem(h, try numSub(h, neg_sq, fx(1)), over)).asFixnum());
    try testing.expect(dispatch_mod.equal(try numMod(h, try numSub(h, neg_sq, fx(1)), over), try numSub(h, over, fx(1))));
    try testing.expect(dispatch_mod.equal(try numAbs(h, neg_sq), sq));
    // Contagion with a bignum operand.
    try testing.expectEqual(@as(f64, 140737488355328.5), (try numAdd(h, over, fl(0.5))).asFloat());
    try testing.expectEqual(@as(f64, 70368744177664.0), (try numDiv(h, over, fl(2.0))).asFloat());
    try testing.expectError(VmError.KindMismatch, numAdd(h, over, value_mod.nilValue()));
    try testing.expectError(VmError.KindMismatch, numMod(h, value_mod.nilValue(), over));
    // The same magnitudes are fine as floats.
    const big = try numMul(h, fl(@floatFromInt(value_mod.fixnum_max)), fx(value_mod.fixnum_max));
    try testing.expect(big.isFloat());
    try testing.expect(std.math.isInf((try numMul(h, fl(1e308), fx(10))).asFloat()));
}

test "numeric tower: division by zero" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const h = &heap;
    try testing.expectError(VmError.DivideByZero, numDiv(h, fx(1), fx(0)));
    try testing.expectError(VmError.DivideByZero, numQuot(h, fx(1), fx(0)));
    try testing.expectError(VmError.DivideByZero, numRem(h, fx(1), fx(0)));
    try testing.expectError(VmError.DivideByZero, numMod(h, fx(1), fx(0)));
    try testing.expectError(VmError.DivideByZero, numQuot(h, fl(1.0), fl(0.0)));
    try testing.expectError(VmError.DivideByZero, numMod(h, fx(1), fl(0.0)));
    const over = try numAdd(h, fx(value_mod.fixnum_max), fx(1));
    try testing.expectError(VmError.DivideByZero, numDiv(h, over, fx(0)));
    try testing.expectError(VmError.DivideByZero, numQuot(h, over, fx(0)));
    try testing.expectError(VmError.DivideByZero, numMod(h, over, fx(0)));
    // Float `/` is IEEE.
    try testing.expect(std.math.isPositiveInf((try numDiv(h, fl(1.0), fx(0))).asFloat()));
    try testing.expect(std.math.isNegativeInf((try numDiv(h, fx(-1), fl(0.0))).asFloat()));
    try testing.expect(std.math.isNan((try numDiv(h, fl(0.0), fl(0.0))).asFloat()));
    try testing.expect(std.math.isPositiveInf((try numDiv(h, over, fl(0.0))).asFloat()));
}

test "numeric tower: comparison across kinds and NaN" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const h = &heap;
    try testing.expect(try numCompare(.lt, fx(1), fl(1.5)));
    try testing.expect(try numCompare(.gt, fl(1.5), fx(1)));
    try testing.expect(try numCompare(.lte, fx(2), fl(2.0)));
    try testing.expect(try numCompare(.gte, fl(2.0), fx(2)));
    try testing.expect(try numCompare(.eq, fx(1), fl(1.0)));
    try testing.expect(!try numCompare(.eq, fx(1), fl(1.5)));
    try testing.expect(try numCompare(.lt, fx(value_mod.fixnum_min), fx(value_mod.fixnum_max)));
    const nan = fl(std.math.nan(f64));
    try testing.expect(!try numCompare(.lt, nan, fx(1)));
    try testing.expect(!try numCompare(.gte, nan, fx(1)));
    try testing.expect(!try numCompare(.eq, nan, nan));
    try testing.expectError(VmError.KindMismatch, numCompare(.lt, fx(1), value_mod.nilValue()));
    try testing.expectError(VmError.KindMismatch, numAdd(h, fx(1), value_mod.fromBool(true)));
    // Bignums order exactly against fixnums, floats and each other.
    const over = try numAdd(h, fx(value_mod.fixnum_max), fx(1));
    const under = try numSub(h, fx(value_mod.fixnum_min), fx(1));
    try testing.expect(try numCompare(.gt, over, fx(value_mod.fixnum_max)));
    try testing.expect(try numCompare(.lt, under, fx(value_mod.fixnum_min)));
    try testing.expect(try numCompare(.lt, under, over));
    try testing.expect(try numCompare(.eq, over, try numAdd(h, fx(1), fx(value_mod.fixnum_max))));
    try testing.expect(try numCompare(.lt, over, try numAdd(h, over, fx(1))));
    try testing.expect(try numCompare(.eq, over, fl(140737488355328.0)));
    try testing.expect(try numCompare(.gt, over, fl(1.5)));
    try testing.expect(!try numCompare(.lt, nan, over));
    try testing.expectError(VmError.KindMismatch, numCompare(.lt, over, value_mod.nilValue()));
    // Sign and extremum.
    try testing.expectEqual(std.math.Order.lt, (try numSign(fl(-0.5))).?);
    try testing.expectEqual(std.math.Order.eq, (try numSign(fl(-0.0))).?);
    try testing.expectEqual(std.math.Order.gt, (try numSign(fx(3))).?);
    try testing.expectEqual(std.math.Order.gt, (try numSign(over)).?);
    try testing.expectEqual(std.math.Order.lt, (try numSign(under)).?);
    try testing.expectEqual(@as(?std.math.Order, null), try numSign(nan));
    try testing.expectError(VmError.KindMismatch, numSign(value_mod.nilValue()));
    try testing.expectEqual(@as(i64, 4), (try numExtremum(true, fx(3), fx(4))).asFixnum());
    try testing.expectEqual(@as(f64, 4.0), (try numExtremum(true, fx(3), fl(4.0))).asFloat());
    try testing.expectEqual(@as(i64, 3), (try numExtremum(false, fx(3), fl(4.0))).asFixnum());
    try testing.expectEqual(@as(i64, 2), (try numExtremum(true, fx(2), fl(1.0))).asFixnum());
    try testing.expectEqual(@as(f64, 1.0), (try numExtremum(true, fx(1), fl(1.0))).asFloat());
    try testing.expect(std.math.isNan((try numExtremum(true, nan, fx(4))).asFloat()));
    try testing.expect(dispatch_mod.equal(try numExtremum(true, fx(4), over), over));
    try testing.expect(dispatch_mod.equal(try numExtremum(false, fx(4), over), fx(4)));
    try testing.expect(dispatch_mod.equal(try numExtremum(true, under, over), over));
    try testing.expect(dispatch_mod.equal(try numExtremum(false, under, over), under));
    const over1 = try numAdd(h, over, fx(1));
    try testing.expect(dispatch_mod.equal(try numExtremum(true, over, over1), over1));
    // Conversions.
    try testing.expect(dispatch_mod.equal(try numLong(h, over), over));
    try testing.expectEqual(@as(i64, 3), (try numLong(h, fl(3.99))).asFixnum());
    try testing.expectEqual(@as(i64, -3), (try numLong(h, fl(-3.99))).asFixnum());
    try testing.expect(dispatch_mod.equal(try numLong(h, fl(140737488355328.0)), over));
    try testing.expectError(VmError.InvalidArgument, numLong(h, nan));
    try testing.expectError(VmError.InvalidArgument, numLong(h, fl(std.math.inf(f64))));
    try testing.expectError(VmError.KindMismatch, numLong(h, value_mod.nilValue()));
    try testing.expectEqual(@as(f64, 140737488355328.0), (try numDouble(over)).asFloat());
    try testing.expectEqual(@as(f64, 3.0), (try numDouble(fx(3))).asFloat());
    try testing.expectEqual(@as(f64, 1.5), (try numDouble(fl(1.5))).asFloat());
    try testing.expectError(VmError.KindMismatch, numDouble(value_mod.fromBool(true)));
    // Parity.
    try testing.expect(try numEven(over));
    try testing.expect(!try numEven(over1));
    try testing.expect(!try numEven(under));
    try testing.expect(try numEven(fx(0)));
    try testing.expectError(VmError.KindMismatch, numEven(fl(2.0)));
}

test "callValue: keywords, maps, sets and vectors are invocable as lookups" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "lookup"));
    defer vm.deinit();
    const heap = vm.ensureHeap();
    const k = vm.ensureInterner().internKeywordValue("k") catch unreachable;
    const other = vm.ensureInterner().internKeywordValue("other") catch unreachable;
    var m = try champ_mod.mapEmpty(heap);
    m = try champ_mod.mapAssoc(heap, m, k, fx(1), &dispatch_mod.hashValue, &dispatch_mod.equal);
    var set = try champ_mod.setEmpty(heap);
    set = try champ_mod.setConj(heap, set, fx(5), &dispatch_mod.hashValue, &dispatch_mod.equal);
    const vec = try vector_mod.fromSlice(heap, &.{ fx(10), fx(20) });

    // (:k m) / (:k m default) / (:other m default) / (:k nil) / (:k 5)
    try testing.expectEqual(@as(i64, 1), (try vm.callValue(k, &.{m})).asFixnum());
    try testing.expectEqual(@as(i64, 1), (try vm.callValue(k, &.{ m, fx(9) })).asFixnum());
    try testing.expectEqual(@as(i64, 9), (try vm.callValue(other, &.{ m, fx(9) })).asFixnum());
    try testing.expect((try vm.callValue(k, &.{value_mod.nilValue()})).isNil());
    try testing.expect((try vm.callValue(k, &.{fx(5)})).isNil());
    try testing.expectError(VmError.ArityMismatch, vm.callValue(k, &.{}));
    try testing.expectError(VmError.ArityMismatch, vm.callValue(k, &.{ m, m, m }));
    // (m :k) / (m :other :d)
    try testing.expectEqual(@as(i64, 1), (try vm.callValue(m, &.{k})).asFixnum());
    try testing.expectEqual(@as(i64, 9), (try vm.callValue(m, &.{ other, fx(9) })).asFixnum());
    // (s 5) / (s 6)
    try testing.expectEqual(@as(i64, 5), (try vm.callValue(set, &.{fx(5)})).asFixnum());
    try testing.expect((try vm.callValue(set, &.{fx(6)})).isNil());
    try testing.expectError(VmError.ArityMismatch, vm.callValue(set, &.{ fx(5), fx(6) }));
    // (v 1) / (v 2) / (v :k)
    try testing.expectEqual(@as(i64, 20), (try vm.callValue(vec, &.{fx(1)})).asFixnum());
    try testing.expectError(VmError.IndexOutOfBounds, vm.callValue(vec, &.{fx(2)}));
    try testing.expectError(VmError.KindMismatch, vm.callValue(vec, &.{k}));
    // Numbers stay uncallable.
    try testing.expectError(VmError.NotCallable, vm.callValue(fx(1), &.{fx(2)}));
}

test "VM math/cmp opcodes cover every wired variant" {
    const consts = [_]Const{
        cval(fx(7)),
        cval(fx(2)),
        cval(fl(0.5)),
    };
    var code = [_]Inst{
        Inst.primary(.math, Math.sub, Operand.slot(0), Operand.constant(0), Operand.constant(1)), // 5
        Inst.primary(.math, Math.mul, Operand.slot(1), Operand.slot(0), Operand.constant(1)), // 10
        Inst.primary(.math, Math.div, Operand.slot(2), Operand.slot(1), Operand.constant(1)), // 5
        Inst.primary(.math, Math.idiv, Operand.slot(3), Operand.constant(0), Operand.constant(1)), // 3
        Inst.primary(.math, Math.mod, Operand.slot(4), Operand.constant(0), Operand.constant(1)), // 1
        Inst.primary(.math, Math.neg, Operand.slot(5), Operand.slot(4), Operand.none), // -1
        Inst.primary(.math, Math.abs, Operand.slot(6), Operand.slot(5), Operand.none), // 1
        Inst.primary(.cmp, Cmp.lte, Operand.slot(7), Operand.slot(6), Operand.constant(1)), // true
        Inst.primary(.cmp, Cmp.gt, Operand.slot(8), Operand.slot(6), Operand.constant(2)), // true
        Inst.primary(.cmp, Cmp.gte, Operand.slot(9), Operand.constant(2), Operand.slot(6)), // false
        Inst.primary(.cmp, Cmp.eq_num, Operand.slot(10), Operand.slot(2), Operand.slot(0)), // true
        asm_.returnSlot(10),
    };
    const routine = makeRoutine(&code, &consts, 11, "math-cmp");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.asBool());
    try testing.expectEqual(@as(i64, 5), vm.stack.items[0].asFixnum());
    try testing.expectEqual(@as(i64, 10), vm.stack.items[1].asFixnum());
    try testing.expectEqual(@as(i64, 5), vm.stack.items[2].asFixnum());
    try testing.expectEqual(@as(i64, 3), vm.stack.items[3].asFixnum());
    try testing.expectEqual(@as(i64, 1), vm.stack.items[4].asFixnum());
    try testing.expectEqual(@as(i64, -1), vm.stack.items[5].asFixnum());
    try testing.expectEqual(@as(i64, 1), vm.stack.items[6].asFixnum());
    try testing.expect(vm.stack.items[7].asBool());
    try testing.expect(vm.stack.items[8].asBool());
    try testing.expect(!vm.stack.items[9].asBool());
}

test "VM math:add: a sum below i48 promotes to a negative bignum" {
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
    const res = try vm.run();
    try testing.expect(res.kind() == .bignum);
    try testing.expect(bignum_mod.isNegative(res));
    try testing.expectEqual((@as(u64, 1) << 47) + 1, bignum_mod.limbs(res)[0]);
}

test "VM math:add: dst/src aliasing is well-defined (math:add s0, s0, c0)" {
    // The handler must resolve BOTH source operands BEFORE
    // writing the destination. Otherwise an aliased dst+lhs
    // (or dst+rhs) would silently produce wrong results when
    // codegen reuses slots.
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
    // codegen emits.
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

// ---- cmp:lt tests ----

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

test "VM cmp: unrecognized variant returns BytecodeCorruption" {
    var code = [_]Inst{
        Inst.primary(.cmp, @as(Cmp, @enumFromInt(9)), Operand.slot(0), Operand.slot(0), Operand.slot(0)),
        asm_.returnNil(),
    };
    const routine = makeRoutine(&code, &.{}, 1, "cmp-bad-variant");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.BytecodeCorruption, res);
}

// ---- Var + Namespace + var:load-var tests ----

test "VM var: Namespace.intern creates an unbound Var, lookup returns it" {
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

test "VM var: var:load-var returns var.root for bound var" {
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
    // tests-only API; the compiler sets this up through
    // `Routine.var_table`.
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
    try vm.retargetTop(&routine);
    const result = try vm.run();
    try testing.expect(result.isFixnum());
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "VM var: var:load-var on unbound Var traps :unbound-var" {
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
    try vm.retargetTop(&routine);
    const res = vm.run();
    try testing.expectError(VmError.UnboundVar, res);
}

test "VM var: var:load-var operand index out of range traps :operand-out-of-range" {
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
    try vm.retargetTop(&routine);
    const res = vm.run();
    try testing.expectError(VmError.OperandOutOfRange, res);
}

test "VM var: var:load-var with non-V B operand traps :invalid-operand-kind" {
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
    try vm.retargetTop(&routine);
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

// ---- var:store-var + var:var-object tests ----

test "VM var store: var:store-var sets root, marks bound, returns Var object" {
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
    try vm.retargetTop(&routine);

    const result = try vm.run();
    // store-var returns the Var object, not the value.
    try testing.expect(result.kind() == .var_);
    try testing.expectEqual(x, VM.asVar(result));
    // Var state is now bound to 42.
    try testing.expect(x.bound);
    try testing.expectEqual(@as(i64, 42), x.root.asFixnum());
}

test "VM var store: var:store-var twice preserves Var identity (rebind in place)" {
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
    try vm.retargetTop(&routine);

    const result = try vm.run();
    try testing.expect(result.kind() == .var_);
    try testing.expectEqual(x, VM.asVar(result));
    try testing.expectEqual(@as(i64, 10), x.root.asFixnum());
}

test "VM var store: var:var-object returns the Var WITHOUT trapping on unbound" {
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
    try vm.retargetTop(&routine);

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
    // of jump(0). Without the kind check this would loop forever.
    // With the kind check it surfaces a clean error.
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
    const res = vm.run();
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
    const res = vm.run();
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
    // store context, NOT "known but not wired".
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

// ---- closure + call tests ----

test "VM closure call: closure:make produces a function-kind Value" {
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

test "VM closure call: ((fn* [] 42)) — no-arg closure call returns its body value" {
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

test "VM closure call: ((fn* [x] (+ x 1)) 5) = 6 — single arg" {
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

test "VM closure call: ((fn* [x y] (+ x y)) 3 4) = 7 — two-arg call" {
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

test "VM closure call: arity mismatch — too few args traps :arity-mismatch" {
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

test "VM closure call: arity mismatch — too many args traps :arity-mismatch" {
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

test "VM closure call: not-callable — call:call on a fixnum traps :not-callable" {
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

test "VM closure call: mov:load-const with routine-typed Const traps :invalid-operand-kind" {
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

test "VM closure call: closure:make with value-typed Const traps :invalid-operand-kind" {
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

test "VM closure call: closure:make capture descriptor source-count mismatch traps" {
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

test "VM closure call: callee local slots are nil-initialized even when stack overlaps caller high slots" {
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

test "VM closure call: call:call with constant operand as A traps :invalid-operand-kind" {
    // call:call requires A=slot (the call_base). A=constant is
    // invalid.
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

test "VM closure call: call:call with constant operand as C traps :invalid-operand-kind" {
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

test "VM closure call: closure:make with capture descriptor index out of range traps OperandOutOfRange" {
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

// ---- cell operations + U-operand tests ----

test "VM capture: closure:box-local wraps slot value into an UpvalCell" {
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

test "VM capture: closure:box-local on already-boxed slot traps :invalid-cell-state" {
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

test "VM capture: closure:get-cell reads cell contents back" {
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

test "VM capture: closure:get-cell on non-cell traps :expected-cell" {
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

test "VM capture: mov:move with U-operand source resolves cell contents (no opcode needed)" {
    // There is no dedicated closure:read-upval —
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

test "VM capture: U-operand out of range traps :upvalue-out-of-range" {
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

test "VM capture: closure:make with local_cell_slot source populates closure.upvalues" {
    // Standalone test of closure:make's descriptor execution
    // (the closure-call tests all use empty descriptors).
    // Box a slot, then closure:make with one
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

// ---- placeholder cell tests ----

test "VM cells: closure:new-cell creates uninitialized cell" {
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

test "VM cells: U-operand resolve on uninitialized cell traps :uninitialized-cell" {
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

test "VM cells: closure:init-cell flips initialized=true and stores value" {
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

test "VM cells: closure:init-cell on already-initialized cell traps :invalid-cell-state" {
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

test "VM cells: closure:init-cell with non-slot A traps :invalid-operand-kind" {
    // Validate destination operand kind before any reads or
    // writes.
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

test "VM cells: closure:init-cell on non-cell traps :expected-cell" {
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

test "VM cells: placeholder pattern — new-cell + make + init enables self-recursion" {
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

test "VM closure call: same closure called twice — both invocations succeed" {
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

test "VM math: unimplemented variant (pow) returns UnimplementedOpcode" {
    // math:pow is reserved per PLAN §12.3 but not wired. Dispatch
    // must surface UnimplementedOpcode, not BytecodeCorruption.
    const math_pow: Inst = .{
        .kind = .primary,
        .group = @intFromEnum(Group.math),
        .variant = @intFromEnum(Math.pow),
        .a = Operand.slot(0),
        .b = Operand.slot(0),
        .c = Operand.slot(0),
    };
    var code = [_]Inst{ math_pow, asm_.returnNil() };
    const routine = makeRoutine(&code, &.{}, 1, "math-pow-unimpl");

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
