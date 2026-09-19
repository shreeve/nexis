## GC.md — Precise Mark-Sweep Garbage Collector

Authoritative contract for `src/gc.zig`. Derivative from `PLAN.md`
§10, `docs/VALUE.md` §5 (mark bits), and `docs/HEAP.md` (allocator +
`sweepUnmarked`). Those documents win on conflict.

`src/gc.zig`'s `Collector.collect` drives the mark phase via caller-
supplied roots and per-kind tracing; `Heap.sweepUnmarked` is the
sweep half. Every heap kind is designed for this collector: each
exports a `trace` function (§5).

**The collector is explicit-only, non-reentrant, precise mark-sweep
with caller-supplied roots.** No auto-trigger, no allocation-
threshold policy, no stack scanning, no generational/concurrent
phases, no write barriers. Each absence is pinned in §9.

**The runtime never invokes the collector.** Nothing in `src/vm.zig`,
`src/cli.zig`, or `src/stdlib.zig` imports `gc.zig` or calls
`Collector.collect`. The VM's `Heap` is backed by `VM.runtime_arena`
(`VM.ensureHeap`) and behaves as a runtime arena released at VM
teardown. The collector is driven by `src/gc.zig`'s inline tests,
`test/prop/gc.zig`, and `test/prop/transient.zig` (§10).

---

### 1. Strategy (PLAN §10.1 frozen)

**Precise, non-moving, stop-the-world mark-sweep** over the runtime
heap managed by `src/heap.zig`. Caller-supplied roots; per-kind
precise tracing. Single-isolate, single-threaded execution makes STW
trivially correct. Non-moving simplifies interaction with intern
tables, emdb-backed byte slices, and native handles.

Mark-sweep is the "first" choice per PLAN §10.3:
  - Smaller blast radius if the collector has bugs.
  - Code is small enough to audit in one sitting.
  - Replacing the collector with a generational one is an isolated
    refactor.
  - No multithreading means no write barriers.

---

### 2. What is (and is not) under collector ownership

The collector operates on **heap blocks** allocated through
`Heap.alloc`. Only these are subject to mark-sweep. Ownership
boundaries that matter:

| Storage                                      | Owner         | Collected? |
|----------------------------------------------|---------------|------------|
| `*HeapHeader` blocks from `Heap.alloc`       | `src/heap.zig`| YES |
| Intern-table name-byte duplications          | `src/intern.zig` | NO — freed on Interner.deinit |
| Intern-table StringHashMap / ArrayList storage | `src/intern.zig` | NO — freed on Interner.deinit |
| Parser / reader Form trees                   | Caller arena  | NO — arena-freed per PLAN §10.7 |
| Macro-expansion intermediates                | Caller arena  | NO — arena-freed |
| Closures (`VM.allocClosure`) and Vars        | `VM.runtime_arena` | NO — not `HeapHeader` blocks |
| String literals in `Routine.consts`          | registry heap (`Heap.alloc`) | YES in principle (§11.5) |

The collector **does not** touch any of the "NO" categories. If a
runtime heap object points into non-collected storage (e.g. a
`symbol_meta` heap block pointing to an intern-table name slice),
the pointer is data, not a GC edge — the tracer walks the heap
block but does not follow the byte pointer into intern storage.

**Intern table trace seam.** `Interner.trace(visitor)` is a no-op
because intern-owned storage is not heap-allocated in the
HeapHeader sense. The seam exists for API stability against a
hypothetical design in which intern entries themselves live on the
heap.

---

### 3. Root model (what counts as a root)

A **root** is a `*HeapHeader` the caller declares "definitely live."
The collector marks each root and recursively traces children.
Anything unreachable from the root set, not `isPinned`, is freed.

**The runtime supplies no roots.** Roots are exclusively
caller-supplied (test fixtures). The collector API has the shape a
runtime-driven collection would use; no runtime module enumerates
its state as roots.

PLAN §10.5 names the root set a runtime-driven collection would
enumerate. Its status in the tree:

1. Executing VM frames (`VM.frames`: slot windows, upvalue arrays).
   — exist; not enumerated.
2. Namespace var tables (`Namespace.vars` in the
   `NamespaceRegistry`). — exist; not enumerated.
3. Intern tables (symbol, keyword, string). — `Interner.trace`
   seam exists and is a no-op.
4. Dynamic-binding stack. — the VM has none.
5. Pinned objects: open transactions, durable-ref handles with
   active reads. — no runtime module pins a block (below).
6. REPL history buffer. — the CLI keeps none.

**`pinned` vs root.** A root is what the collector starts marking
from. A pinned block (`HeapHeader.isPinned() == true`) survives
sweep regardless of mark state, even if unreachable from any root.
Pinning is for resources the collector must not reclaim but cannot
prove reachable through normal tracing — e.g. a durable-ref holding
an open read cursor against emdb. The heap provides the bit and
`sweepUnmarked` honors it; only tests call `setPinned`.

---

### 4. Collector API

```zig
pub const Collector = struct {
    heap: *Heap,
    collecting: bool = false,

    pub fn init(heap: *Heap) Collector;

    /// Start a reachability walk from a `Value`. If `v` is an
    /// immediate, does nothing. If `v` is a heap-kind Value, marks
    /// the underlying *HeapHeader (and recursively its children).
    /// Safe entry point for callers holding Values.
    pub fn markValue(self: *Collector, v: Value) void;

    /// Mark a full heap object and recursively walk its children.
    /// Idempotent via mark-bit. Handles:
    ///   - mark bit transition (once-only walk)
    ///   - meta chain: if `h.meta != null`, recursively marks `h.meta`
    ///   - kind dispatch: invokes the per-kind trace function
    pub fn mark(self: *Collector, h: *HeapHeader) void;

    /// Mark an INTERNAL heap node (collection-internal subkind, never
    /// a user-visible Value). Returns `true` if this call flipped
    /// the mark bit (caller should then walk its payload), `false`
    /// if the node was already marked (skip walking).
    ///
    /// Does NOT walk `h.meta` — internal nodes have no metadata
    /// semantics. Does NOT dispatch on `h.kind` — the caller
    /// knows the structural context and will walk the payload itself.
    ///
    /// Used by `vector.trace` and `hamt.traceMap`/`traceSet` to mark
    /// trie/interior/collision nodes without needing body-shape
    /// heuristics or a subkind byte in `HeapHeader`: mark-bit state
    /// is centralized on the collector even for internal nodes.
    pub fn markInternal(self: *Collector, h: *HeapHeader) bool;

    /// Run a full collection cycle: mark every root, then sweep
    /// unmarked. Returns the number of blocks freed.
    ///
    /// Not reentrant. Calling `collect` from inside a trace
    /// function or a `mark` callback panics via the
    /// `self.collecting` guard.
    pub fn collect(self: *Collector, roots: []const *HeapHeader) usize;
};
```

**Private primitive** (not exposed but documented so the invariant
is stable):

```zig
fn markHeaderOnce(self: *Collector, h: *HeapHeader) bool {
    if (h.isMarked()) return false;
    h.setMarked();
    return true;
}
```

Both `mark` and `markInternal` route through `markHeaderOnce`. One
owner for the mark-bit state machine.

**Error set.** `collect` has no error returns — sweep is infallible
at the allocator layer (`backing.free` cannot fail). `mark` and
`markInternal` are `void` / `bool` respectively; neither can fail.

**Non-reentrancy.** `collect` asserts `self.collecting == false` at
entry and sets it to `true` for the duration. Any nested `collect`
call panics. Any `mark` / `markInternal` call outside an active
`collect` is legal (tests exercise them directly to verify
individual primitives); those do not set the flag.

---

### 5. Per-kind trace contract

Every heap-kind module provides:

```zig
pub fn trace(h: *HeapHeader, visitor: anytype) void;
```

or, for hamt which hosts two kinds, two functions:

```zig
pub fn traceMap(h: *HeapHeader, visitor: anytype) void;
pub fn traceSet(h: *HeapHeader, visitor: anytype) void;
```

Rules:

1. **Do NOT mark `h` itself.** The collector already marked `h`
   before dispatching here. Setting the mark bit again is
   idempotent but wasted work; more importantly, marking before
   dispatch is what `mark` relies on for cycle safety.
2. **Do NOT walk `h.meta`.** The collector handles meta. Per-kind
   trace ignores the field.
3. **Walk externally-visible Values.** For each `Value` slot the
   object references (map/set elements, list head/tail, vector
   leaf values, etc.) that has `kind().isHeap()` (heap kind, not
   an immediate), call `visitor.markValue(v)` (or equivalently
   `visitor.mark(Heap.asHeapHeader(v))`).
4. **Walk internal nodes directly.** For compound kinds (vector,
   hamt) that hold internal trie / bitmap nodes, the trace
   function walks those nodes itself via `visitor.markInternal(node)`
   — NOT through `visitor.mark`. If `markInternal` returns true,
   the trace function walks the internal node's payload; if false,
   the node was already marked, stop.
5. **Leaf kinds (string, bignum) trace is a no-op.** Their bodies
   are raw bytes / limbs with no heap references. They still
   export `trace` for uniformity.

**Internal nodes are ordinary heap blocks for sweep purposes.**
Vector interior / leaf / tail blocks and CHAMP interior / collision
blocks are allocated through the same `Heap.alloc` as user-visible
roots. They have `HeapHeader.mark` bits and participate in sweep
identically. Their "internal" label refers only to **how they're
traversed**: they are reached via the owning kind's local trace
using `markInternal`, not through the global kind-switch dispatch
in `mark`. Ownership at the allocator layer is identical —
`sweepUnmarked` frees unmarked internal nodes just as it frees
unmarked user-visible roots.

Visitor ABI (duck-typed; Collector conforms):

```zig
fn markValue(v: Value) void;
fn mark(h: *HeapHeader) void;
fn markInternal(h: *HeapHeader) bool;
```

Kind dispatch table (`Collector.mark`):

| Kind                  | trace function             | Walks                                       |
|-----------------------|----------------------------|---------------------------------------------|
| `.string`             | `string.trace`             | nothing (byte bodies)                       |
| `.bignum`             | `bignum.trace`             | nothing (limb bodies)                       |
| `.list`               | `list.trace`               | cons head + tail; empty-list is no-op       |
| `.persistent_vector`  | `vector.trace`             | trie (internal nodes via `markInternal`) + tail |
| `.persistent_map`     | `hamt.traceMap`            | array-map entries OR CHAMP subtree          |
| `.persistent_set`     | `hamt.traceSet`            | array-set elements OR CHAMP subtree         |
| `.transient`          | `transient.trace`          | the wrapper's `inner_header` (TRANSIENT.md §10) |
| `.durable_ref`        | `db.trace`                 | nothing (inline identity bytes; `conn` is not heap-managed, DB.md §7.3) |
| `.atom`               | `atom.trace`               | the contained value (ATOM.md §7); `in_flight` is a `u8` |
| `.record`             | `record.trace`             | the field map; `type_id` is a plain `u32` (PROTOCOLS.md §2.1) |
| `.protocol`, `.protocol_fn` | `protocol.trace`     | nothing (leaf bodies)                       |
| `.nextomic_conn`, `.nextomic_db` | inline `{}`     | nothing (a VM-owned pointer plus inline text / numbers) |
| `.typed_vector`       | `typed_vector.trace`       | nothing (unboxed i64 / f64 elements, `docs/TYPED_VECTOR.md` §5) |
| `.byte_vector`        | *panic (unallocated)*      | — |
| `.function`           | *panic (unallocated)*      | — |
| `.var_`               | *panic (unallocated)*      | — |
| `.error_`             | *panic (unallocated)*      | — |
| `.meta_symbol`        | *panic (unallocated)*      | — |

"Panic (unallocated)" means: the kind byte is reserved in VALUE.md
§2.2 but no module allocates blocks with that kind through
`Heap.alloc`. (`.function` Values point at `Closure` structs in
`VM.runtime_arena`, not at `HeapHeader` blocks, so a `.function`
Value must never reach `mark`.) The collector panics loudly if it
encounters one of these kinds during `mark` because hitting the arm
implies memory corruption OR a caller-side bug (constructed a Value
with the wrong kind byte). **Panic, not silent no-op**, because a
silent no-op on a kind that SHOULD trace would create invisible
retention bugs. Any other kind byte (immediates, sentinels) also
panics: it cannot appear on a heap header.

---

### 6. Meta chain handling

`HeapHeader.meta` is a `?*HeapHeader` pointing (when non-null) at a
metadata-bearing persistent-map root. Per SEMANTICS.md §7 and PLAN
§23 #12, metadata never participates in equality or hash. From the
GC's perspective, however, it's a live reference — if an object is
reachable, its metadata map must also survive.

The collector walks the meta chain centrally in `mark`:

```zig
pub fn mark(self: *Collector, h: *HeapHeader) void {
    if (!self.markHeaderOnce(h)) return;
    if (h.meta) |m| self.mark(m);  // recurses; handles cycles by mark-bit
    dispatch_by_kind(h, self);
}
```

Per-kind trace code ignores the field. Internal nodes are NOT
metadata-bearing (CHAMP.md §8.2 and VECTOR.md §3 both pin
metadata to user-facing roots only), so `markInternal` intentionally
skips the meta walk.

---

### 7. Collection cycle

```
collect(roots):
    assert !self.collecting
    self.collecting = true
    defer self.collecting = false

    for each r in roots:
        self.mark(r)             // marks reachable transitive closure

    freed = self.heap.sweepUnmarked()  // clears marked bit on survivors;
                                        // frees unmarked, non-pinned blocks
    return freed
```

`Heap.sweepUnmarked`:
  - Skips pinned blocks (even if unmarked).
  - Clears `marked` on surviving blocks so the next cycle starts
    fresh.
  - Poisons freed blocks' kind bytes for double-free detection.

The collector is stateless between cycles. Each call to `collect`
starts from cleared mark bits (from the previous cycle's sweep) and
ends with cleared mark bits (from the current cycle's sweep).

---

### 8. Cycle safety

The persistent heap kinds are **acyclic by construction under
normal API use** — persistent collections are immutable, so once a
node is built its children are fixed. Metadata chains can only
point forward (from a heap object to its meta map), not back,
because nothing mutates an existing block's meta field after an
already-reachable object has consumed it as a child.

Atoms CAN form cycles: an atom's contained value may reach the atom
itself. The collector performs mark-bit idempotence
**unconditionally** via `markHeaderOnce`: a second visit to an
already-marked node returns immediately. So atoms, and any other
heap kind or metadata graph that can form cycles (Vars capturing
closures that reference the var back; user-synthesized metadata
loops if the surface language ever admits them; transient mutation
during an in-progress construction), are safe by the same mechanism,
with no API changes.

---

### 9. Absent, explicitly

Each of the following does not exist. The shape of the collector
is forward-compatible with all of them:

- **Auto-trigger.** PLAN §10.6 specifies allocation-threshold-based
  triggering (`N bytes since last collection`). The collector is
  explicit-only — callers invoke `collect` directly. `Heap.alloc`
  keeps no byte counter, `Collector` has no threshold config, and
  no allocation path checks either.
- **Stack scanning.** Not planned per PLAN §10.5 — the VM is
  frame/slot-based and maintains its own precise slot windows. A
  conservative stack scanner is not required and does not exist.
- **Write barriers.** Single-threaded mark-sweep has no data races
  and no generational / remembered-set concerns. A generational
  design (PLAN §10.3) would introduce a young-space / remembered-
  set barrier; none exists.
- **Concurrent / incremental GC.** Single-isolate; STW is
  acceptable.
- **Finalizers.** None. Objects that own OS resources (open
  files, pinned durable-ref reads) are tracked separately at the
  tx/db layer via explicit close calls.
- **Transient ownership tracking by GC.** The owner-token
  machinery lives at the kind level (`src/coll/transient.zig`); GC
  treats transients as regular heap objects (their `trace` walks
  the inner structure; their mutability is orthogonal).

---

### 10. Testing

Inline tests in `src/gc.zig` cover structural correctness:

- Empty root set: every live block is freed.
- Flat roots: only roots survive.
- Nested reachability: list-of-lists where only the outer list is a
  root; every inner list survives.
- Cross-kind graph: a persistent map whose values are lists.
- CHAMP-backed map and set (>8 entries) survive: exercises
  `markInternal` on internal nodes.
- Vector with a deep trie survives end-to-end.
- Atom: the contained value survives via trace; an unreferenced
  contained value that the atom does not hold is swept.
- Pinned blocks survive even without being in the root set.
- Idempotence: `collect(roots)` called twice in a row; second call
  frees 0 blocks (marks clear from first call's sweep); sweep clears
  mark bits on survivors.
- `markInternal` return value: true on first call, false on second;
  `mark` idempotent across direct calls; `markValue` no-op on
  immediates.
- Non-reentrancy: calling `collect` from inside a visitor callback
  panics.
- Metadata chain: reachable through `h.meta`; a meta-only
  unreachable block is swept.

Property tests in `test/prop/gc.zig` exercise randomized graphs:

- G1: random flat blocks with a random root subset.
- G2: nested graph — the reachable closure, tracked in a parallel
  model, exactly matches `liveCount` after `collect`.
- G3: collect twice with the same roots — second call frees 0.
- G4: pinned block survives without roots; unpinning releases it.
- G5: repeated allocate-and-collect cycles do not leak.

`test/prop/heap.zig` (H2, H3, H6) drives `sweepUnmarked` directly
with mark bits set by hand; it tests the sweep primitive, not the
collector. `test/prop/transient.zig` T4/T4b collect with a transient
wrapper as the sole root.

---

### 11. Module graph

```
gc.zig
├─ @import("heap")             — HeapHeader + Heap + sweepUnmarked
├─ @import("value")            — Value + Kind
├─ @import("string")           — string.trace
├─ @import("bignum")           — bignum.trace
├─ @import("list")             — list.trace
├─ @import("vector")           — vector.trace
├─ @import("champ")            — champ.traceMap + champ.traceSet
├─ @import("typed_vector")     — typed_vector.trace (leaf)
├─ @import("transient")        — transient.trace
├─ @import("db")               — db.trace
├─ @import("atom")             — atom.trace
├─ @import("record")           — record.trace
├─ @import("protocol")         — protocol.trace
└─ @import("nextomic_handle")  — kind constants (leaf handles)
```

One-way terminal, same discipline as `dispatch.zig`. No heap-kind
module imports `gc.zig`. Per-kind modules receive the visitor as
`anytype`; `gc.Collector` satisfies the duck-typed interface
(`markValue`, `mark`, `markInternal`).

---

### 11.5 Rooting hazards under a triggered collector

The collector is explicit-only (§9); `heap.alloc` never triggers a
collection. Under any allocation-triggered design (or a generational
nursery), every native fn that allocates **after** holding Values
only in Zig locals is a rooting hazard. The pattern looks like:

```zig
old = read_some_value();
new = try vm.callValue(f, args);
mutate_some_state(new);              // may drop last edge to `old`
return try build_vector(old, new);   // alloc may trigger GC; `old`
                                     // only in Zig local — at risk
```

**General rule:** any native fn that calls `heap.alloc` (or any
allocating helper that may transitively call it) while holding
non-rooted `Value`s in Zig locals must either root those Values
(via a root-stack API, which does not exist) or prove they are still
reachable from VM slots / Vars / heap collections that are themselves
rooted.

Sites in `src/stdlib.zig` with this shape:

- `fnAtom` — single `atom_mod.make` call; the init arg lives in the
  args slice, which the native-call path keeps reachable through
  the caller's slot window for the duration of the call. Safe under
  an explicit-only collector; audit under any triggered design.
- `fnSwapValsBang` — builds `[old new]` vector AFTER writing
  `body.value = new`. (`docs/ATOM.md` §4.5)
- `fnStr`, `fnSubs` — build output strings via `string.fromBytes`
  after the input args have been copied off the stack into the args
  slice (which is reachable from the calling frame).
- `nexis.string/*` fns (`fnStringLowerCase`, `fnStringUpperCase`,
  `fnStringTrim`, `fnStringSplit`, `fnStringJoin`,
  `fnStringReplace`) — allocate output strings/vectors after holding
  inputs in Zig locals: `fromBytes` outputs; `split` collects
  fragments into a `vector.fromSlice`; `join` and `replace` build a
  byte buffer then `fromBytes`. Each call's input args are reachable
  through the args slice; the intermediate byte buffers are owned by
  the function's local `std.ArrayList(u8)` freed on return.
- Printing + I/O fns — build into a `std.Io.Writer.Allocating`
  buffer before either writing to stdout or producing a heap-string
  Value: `fnPrint`/`fnPrintln`/`fnPrn` (display/readable into
  buffer, then `writeStreamingAll` to stdout); `fnPrStr` (readable
  into buffer, then `string.fromBytes`); `fnSlurp` (read file into
  caller-allocator byte slice, validate UTF-8, then
  `string.fromBytes`); `fnSpit` (str-stringify into buffer, then
  `writeFile`). Input args stay reachable through the args slice;
  intermediate buffers are freed on return; output string Values
  are allocated AFTER all input use is complete. The central
  `src/format.zig` formatter walks any Value tree into a writer with
  no inputs held in Zig locals across allocations (pure-write, not
  allocate-then-mutate). The audit point under a triggered design is
  the `Allocating` buffer's intermediate bytes if a collection fires
  between the buffer's first write and the final `fromBytes`.
- `buildListFromSlice` — cons calls between iterations hold the
  intermediate `result` in a Zig local; the function's doc comment
  flags the un-rooted partial result.
- `fnApply` / HOF callbacks generally — any `vm.callValue`
  invocation called between allocations.
- `fnDbAlter` — the write happens AFTER `callValue`, so `old`/`new`
  are not at risk in this fn specifically, but the reentrancy of
  `vm.callValue` itself is the hazard class.
- **Catch-all**: every entry in `core_fns` / `db_fns` that calls
  `heap.alloc` directly or indirectly is in scope; the list above is
  the known-non-trivial subset. Every native fn documents its rooting
  story or extends this list.

**Routine const pools.** Compile-time-allocated heap Values appear
in `Routine.consts[i].value`: **source string literals** (`"hello"`
lowers via `string.fromBytes` against the heap reachable through
`namespace.registry.heap`). Reals and chars lower to immediates, so
string literals are the only heap Values in const pools. Under a
triggered design the VM root walk MUST enumerate the const pool of
every reachable `Routine`:

```text
for each frame F on VM.frames:
    for each entry e in F.routine.consts:
        if e == .value and e.value.isHeap():
            mark(e.value's *HeapHeader)
        if e == .routine:
            recurse into e.routine.consts (no allocation, just walk)
```

Plus any `Routine` reachable via closure `prototype` pointers or
the `var_table` `Var.root` chain — those must also have their
const pools walked. None of this is wired because the collector is
explicit-only (§9). Manual `collect` tests build Values directly
from the test harness and never go through routine consts, so the
hazard is structurally absent from the test suite. The
bytecode-load-const + load-var paths DO copy `consts[i].value` into
a slot before any user code can allocate, so a slot-only-tracing
collector that runs strictly between bytecode instructions is still
safe; the hazard window opens with any pre-emption point inside a
sequence of instructions that may allocate (e.g., concurrent /
write-barrier designs).

Requirements for any triggered-collection design:

1. Enumerate `vm.callValue` call sites in `src/stdlib.zig` (and
   `src/db.zig` if it grows similar patterns).
2. For each: classify whether any local Value could become unrooted
   between `callValue` and the next use of that local.
3. Add a root-stack push/pop API (PLAN §10) and wrap exposed sites.
4. Verify with a randomized property test that forces GC at every
   allocation boundary during a `swap!` / `apply` / `reduce` cascade.

---

### 12. What GC.md does not cover

- **Per-kind trace implementations.** Each kind's own doc carries a
  short "Trace function" section describing what it walks
  (HEAP.md / STRING.md / BIGNUM.md / LIST.md / VECTOR.md / CHAMP.md /
  TRANSIENT.md / DB.md / ATOM.md / PROTOCOLS.md).
- **Allocator internals.** HEAP.md is authoritative; the collector
  is a consumer of that API.
- **Intern table internals.** INTERN.md §5 is authoritative on the
  `trace` seam; this doc only notes the ownership boundary.
- **Codec serialization interaction.** None. Codec operations
  do not trigger GC (PLAN §10.6).
