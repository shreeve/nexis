## GC.md — Precise Mark-Sweep Garbage Collector

Authoritative contract for `src/gc.zig`. Derivative from `PLAN.md`
§10, `docs/VALUE.md` §5 (mark bits), and `docs/HEAP.md` (allocator +
`sweepUnmarked`). Those documents win on conflict.

`src/gc.zig`'s `Collector.collect` drives the mark phase from the
caller's roots and the host's, with per-kind tracing;
`Heap.sweepUnmarked` is the sweep half. Every heap kind is designed
for this collector: each exports a `trace` function (§5), and the
two kinds whose layout the VM owns (closures, upvalue cells) trace
through the host hook.

**The collector is precise, non-moving, stop-the-world mark-sweep,
iterative, run by the VM at its safe points.** The VM is the
host: `src/vm.zig` imports `gc.zig`, enumerates the runtime's roots
(§3), traces closures and cells, and runs a cycle between two
instructions once the heap has allocated a threshold of bytes since
the last one (§7). No stack scanning, no generational or concurrent
phases, no write barriers, no finalizers (§9).

A VM with a borrowed heap (the compile-time sub-VMs the expander runs
user macros and `defmacro` bodies on, which allocate on the heap of the VM
whose Vars they use) never collects: it cannot enumerate the owner's
roots. The collector is also driven directly, over a bare heap with
explicit roots, by `src/gc.zig`'s inline tests, `test/prop/gc.zig`
and `test/prop/transient.zig` (§10).

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
| Closures and upvalue cells (`VM.allocClosure`, `VM.allocCell`) | `src/heap.zig` (kinds `function`, `cell_internal`) | YES — traced through the host (§5) |
| String and bignum literals in `Routine.consts` | registry heap (`Heap.alloc`) | YES — rooted through every frame and closure over the routine (§3) |
| Intern-table name-byte duplications          | `src/intern.zig` | NO — freed on Interner.deinit |
| Intern-table StringHashMap / ArrayList storage | `src/intern.zig` | NO — freed on Interner.deinit |
| Parser / reader Form trees                   | Caller arena  | NO — arena-freed per PLAN §10.7 |
| Macro-expansion intermediates                | Caller arena  | NO — arena-freed |
| Vars and namespaces                          | `VM.runtime_arena` | NO — immortal by design; their values are roots (§3) |
| `NativeFn` descriptors, `db.Connection`, db transaction handles | static storage / the VM | NO — pointer kinds with no block; `markValue` skips them (`Heap.isBlockKind`) |

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

A **root** is a block or Value the collector starts marking from.
The collector marks each root and, through the worklist (§4), everything reachable from it.
Anything unreachable from the root set, not `isPinned`, is freed.

Two sources: the explicit `roots` slice `collect` takes (the tests'
fixtures) and the host's `Host.roots` callback, which the VM
implements as `VM.gcRoots`. The VM's roots (PLAN §10.5), in the
order it marks them:

1. **The backing stack, in full** (`vm.stack.items`): every slot of
   every frame's window, and the slots between and above them. A
   slot above a popped frame keeps its stale value until the slot
   is grown into again (`appendNTimes(nil)` on every growth), which
   retains garbage for a while and is sound. A slot holding a
   `.cell_internal` Value marks the cell block like any other.
2. **Every frame**: the closure it runs (`Frame.closure`, which
   keeps the `upvalues` array in the closure block's tail alive;
   its trace reaches the cells and the routine's constants, once
   however many frames run it), or, for a frame with no closure
   (the top-level form, a loader routine), the heap constants of
   its routine, recursively through the routines in the constant
   pool (string and bignum literals).
3. **Every Var of every namespace** in the registry, and of the
   single ad-hoc namespace: `root`, `meta` and `thread_value`. Vars
   are immortal arena objects, so a `var_` Value is never marked
   itself (`Heap.isBlockKind` excludes it); its contents are reached
   only here.
4. **The dynamic-binding stack**: the value each open `binding`
   frame saved (`vm.dyn_saves`); the bindings in force are the Vars'
   `thread_value`, covered by 3.
5. **The root stack** (`vm.roots`): what natives and `callValue`
   push (below).
6. **Pending `finally` throws** (`vm.finally_stack`, the `.throwing`
   continuations), **the unhandled throw** and **the halt result**
   (`vm.result`).
7. **The protocol registry**: every method implementation and
   default implementation.
8. **The Nextomic query caches**: the query value of every entry in
   the per-VM parse and rule caches, through the hook the nextomic
   natives install (`vm.nextomic_query_mark`), since a parse borrows
   from its query value (`docs/NEXTOMIC.md` §5).

The interner holds no heap values (symbols and keywords are
immediates), so `Interner.trace` is a no-op seam. Open `db` and
`nextomic` connections hold no heap values; a `durable_ref`,
`db_read_txn`, `nextomic_db` or `nextomic_entity` handle is reachable
from wherever the program keeps it.

**The root stack.** A cycle can run inside any `VM.callValue`, so a
native that holds a heap Value only in a Zig local across a call
back into the VM must root it first:

- `callValue` pushes a native callee's `args` for the call's
  duration, so a native's arguments are always rooted: through the
  caller's slots when reached by `call:call`, through the root stack
  when reached by `callValue`. A closure callee receives its
  arguments in its own slots.
- Everything reachable from a rooted value is rooted, so an element
  of an argument collection needs nothing.
- A value a callback returned is rooted while it is the next call's
  argument (`reduce`, `reduce-kv`, `swap!`, `db/alter!`,
  `db/reduce-tree` need nothing) and not otherwise: a native that
  accumulates callback results across further callbacks (`map`,
  `filter` in `keep` mode, `map-indexed`, `reductions`, `repeatedly`,
  `iterate`, `sort-by` keys, `max-key`/`min-key` keys) opens a
  `VM.RootScope` and pushes each result; the deferred `release`
  drops them on every exit path, a `ControlTransferred` unwind
  included. The Nextomic `q` hook pushes every value a user function
  returns to the pipeline for the query's life, since it may sit in
  a relation cell.
- Between two callbacks no cycle can run: `Heap.alloc` never
  collects (§7), so a native may allocate freely while holding
  unrooted locals as long as it does not call back in.

**`pinned` vs root.** A root is what the collector starts marking
from. A pinned block (`HeapHeader.isPinned() == true`) survives
sweep regardless of mark state, even if unreachable from any root.
The heap provides the bit and `sweepUnmarked` honors it; no runtime
module pins a block, and only tests call `setPinned`.

---

### 4. Collector API

```zig
pub const Collector = struct {
    heap: *Heap,
    /// The runtime behind the heap, when there is one.
    host: ?Host = null,
    /// Headers marked but not yet traced.
    gray: std.ArrayList(*HeapHeader) = .empty,
    /// True while a drain runs (all of `collect`): `mark` only pushes.
    draining: bool = false,

    pub const Host = struct {
        ctx: *anyopaque,
        /// Mark every root the host holds; called once per cycle
        /// after the explicit roots.
        roots: *const fn (ctx: *anyopaque, collector: *Collector) void,
        /// Walk the children of an already-marked `function` block
        /// (a closure) or `cell_internal` block (an upvalue cell).
        trace: *const fn (ctx: *anyopaque, h: *HeapHeader, collector: *Collector) void,
    };

    pub fn init(heap: *Heap) Collector;

    /// Start a reachability walk from a `Value`. Immediates and the
    /// pointer kinds with no block (`native_fn`, `var_`, the db
    /// handles; `Heap.isBlockKind`) are ignored. Any other Value
    /// marks the underlying *HeapHeader. Safe entry point for
    /// callers holding Values.
    pub fn markValue(self: *Collector, v: Value) void;

    /// Mark a full heap object: set the mark bit (once only) and
    /// push the header on `gray`. Outside a drain it drains before
    /// returning, so a direct call still marks the transitive
    /// closure.
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

    /// Run a full collection cycle: push every root, then the
    /// host's roots, drain the worklist, then sweep unmarked and
    /// start a new allocation-counting window on the heap. Returns
    /// the number of blocks freed.
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

**Iterative marking.** The mark phase is a loop, never a recursion
on the data: `mark` sets the bit and pushes the header on `gray`;
the drain pops a header, marks its meta map and runs its kind's
trace (§5), whose `mark` / `markValue` calls push in turn. A live
structure nested a million levels deep (a linked list of maps, an
accumulator of nested vectors, a chain of atoms or of meta maps)
costs a million entries of `gray`, not a million native frames.
The per-kind traces keep walking their own interior nodes in place
(`markInternal`), which is bounded: a vector trie is at most seven
levels deep and a CHAMP tree thirteen. If `gray` cannot grow, `mark`
traces the header on the spot instead, so a cycle never fails; only
under memory exhaustion does it recurse. `gray` is freed at the end
of every cycle. A `mark` / `markInternal` call outside `collect` is
legal (tests exercise the primitives directly) and drains before it
returns.

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
| `.list`               | `list.trace`               | every head; the tail chain in a loop (cells via `markInternal`, their meta via `mark`), so depth follows nesting, not length |
| `.persistent_vector`  | `vector.trace`             | trie (internal nodes via `markInternal`) + tail |
| `.persistent_map`     | `hamt.traceMap`            | array-map entries OR CHAMP subtree          |
| `.persistent_set`     | `hamt.traceSet`            | array-set elements OR CHAMP subtree         |
| `.transient`          | `transient.trace`          | the wrapper's `inner_header` (TRANSIENT.md §10) |
| `.durable_ref`        | `db.trace`                 | nothing (inline identity bytes; `conn` is not heap-managed, DB.md §7.3) |
| `.atom`               | `atom.trace`               | the contained value (ATOM.md §7); `in_flight` is a `u8` |
| `.record`             | `record.trace`             | the field map; `type_id` is a plain `u32` (PROTOCOLS.md §2.1) |
| `.protocol`, `.protocol_fn` | `protocol.trace`     | nothing (leaf bodies)                       |
| `.nextomic_conn`, `.nextomic_db` | inline `{}`     | nothing (a VM-owned pointer plus inline text / numbers) |
| `.nextomic_entity`    | `nextomic_handle.traceEntity` | the db box and the map of the entity's last full read (NEXTOMIC.md §6) |
| `.function`           | `Host.trace` (`VM.gcTrace`) | every upvalue cell (`markInternal`-free: cells are blocks of their own kind, marked through `mark`), then the routine's heap constants recursively through nested routines (VM.md §6) |
| `.cell_internal`      | `Host.trace` (`VM.gcTrace`) | the cell's value (VM.md §6) |
| `.typed_vector`       | `typed_vector.trace`       | nothing (unboxed i64 / f64 elements, `docs/TYPED_VECTOR.md` §5) |
| `.byte_vector`        | *panic (unallocated)*      | — |
| `.var_`               | *panic (not a block)*      | — |
| `.error_`             | *panic (unallocated)*      | — |
| `.meta_symbol`        | *panic (unallocated)*      | — |

"Panic (unallocated)" means: the kind byte is reserved in VALUE.md
§2.2 but no module allocates blocks with that kind through
`Heap.alloc`. `.var_` is a Value kind whose payload is an arena
`*Var` (§3), so a `var_` header byte is a corrupted block. A
`.function` or `.cell_internal` block reaching a collector without a
host panics too: only a runtime allocates those kinds. The collector
panics loudly because hitting such an arm implies memory corruption
OR a caller-side bug (constructed a Value with the wrong kind byte).
**Panic, not silent no-op**, because a silent no-op on a kind that
SHOULD trace would create invisible retention bugs. Any other kind
byte (immediates, sentinels) also panics: it cannot appear on a heap
header.

---

### 6. Meta chain handling

`HeapHeader.meta` is a `?*HeapHeader` pointing (when non-null) at a
metadata-bearing persistent-map root. Per SEMANTICS.md §7 and PLAN
§23 #12, metadata never participates in equality or hash. From the
GC's perspective, however, it's a live reference — if an object is
reachable, its metadata map must also survive.

The collector walks the meta chain centrally, when the drain
traces a header:

```zig
fn trace(self: *Collector, h: *HeapHeader) void {
    if (h.meta) |m| self.mark(m);  // pushes; cycles stop at the mark bit
    dispatch_by_kind(h, self);
}
```

Per-kind trace code ignores the field. Internal nodes are NOT
metadata-bearing (CHAMP.md §8.2 and VECTOR.md §3 both pin
metadata to user-facing roots only), so `markInternal` intentionally
skips the meta walk.

---

### 7. Collection cycle, trigger and safe point

```
collect(roots):
    self.draining = true
    for each r in roots:
        self.mark(r)             // sets the bit, pushes on gray
    if host: host.roots(host.ctx, self)
    while gray.pop() |h|: trace(h)   // the transitive closure
    self.draining = false
    free gray

    freed = self.heap.sweepUnmarked()  // clears marked bit on survivors;
                                        // frees unmarked, non-pinned blocks
    self.heap.resetAllocationCounter()
    return freed
```

`Heap.sweepUnmarked`:
  - Skips pinned blocks (even if unmarked).
  - Clears `marked` on surviving blocks so the next cycle starts
    fresh.
  - Poisons freed blocks' kind bytes for double-free detection.
  - Subtracts each freed block from `Heap.live_bytes`.

The collector is stateless between cycles. Each call to `collect`
starts from cleared mark bits (from the previous cycle's sweep) and
ends with cleared mark bits (from the current cycle's sweep).

**Trigger** (PLAN §10.6). `Heap.alloc` counts every byte it hands
out in `allocated_since_collect`; `collect` resets the counter. The
VM owns the policy (`VM.gcDue`): a cycle is due once the counter
reaches `gc_next_at`, which each cycle sets to the larger of
`gc_threshold` (bytes allocated since the last cycle) and
`gc_growth_percent` percent of `Heap.live_bytes` after the sweep, so
a large live set is not re-marked every few kilobytes. The defaults
are `GcPolicy.default` (16 MiB, 100 %); with `NEXIS_GC_STRESS` set
in the environment every VM starts with `GcPolicy.stress` (4 KiB,
0 %), which makes a cycle due every few kilobytes and is how the
suite proves the rooting rules; a test sets the three fields on its
VM to the same effect.

**Safe point.** The VM checks `gcDue` at exactly one place: before
fetching an instruction, in its one run loop (`VM.loop`, which
`run`, `callValue` and `runRoutine` all drive). The check runs at a loop's first
fetch and at every fetch that follows an instruction of a group
that can allocate (`math`, `call`, `closure`, `coll`, `ctrl`); a
`mov`, `cmp`, `jump` or `var` instruction cannot move the heap's
counter, so the fetch after one skips the test. Between two instructions every
live value is in a slot, a frame, a Var, the root stack or one of
the other roots §3 lists, so a cycle there frees nothing live. A
cycle can therefore run inside a native only through a call back
into the VM (`callValue` runs the loop), which is what the
root-stack rule in §3 accounts for. `Heap.alloc` never collects: a
native, the compiler and the `coll:*` instructions allocate as many
blocks as they like between callbacks with no rooting. Everything
the VM allocates inside one instruction (a variadic rest list, a
closure block and its cells) is in a slot before the next fetch.
`VM.collectGarbage` runs a cycle on demand from a safe point; tests
call it directly.

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
- **A per-PC liveness map.** The whole backing stack is a root, so
  a dead slot retains its value until it is overwritten or its frame
  is popped and the slot grown into again.
- **Collection in a sub-VM.** A VM over a borrowed heap never
  collects; its garbage is the owner's to collect after it returns.

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
- Metadata chain: reachable through `h.meta`; a meta-only
  unreachable block is swept.

Property tests in `test/prop/gc.zig` exercise randomized graphs:

- G1: random flat blocks with a random root subset.
- G2: nested graph — the reachable closure, tracked in a parallel
  model, exactly matches `liveCount` after `collect`.
- G3: collect twice with the same roots — second call frees 0.
- G3b: a list of half a million cells survives a cycle intact and
  is freed by the next; the walk is a loop, so length never
  becomes recursion depth.
- G3c: a chain of 300,000 levels alternating vector elements, map
  values, atom values and meta maps survives a cycle intact: the
  worklist keeps nesting depth off the native stack.
- G4: pinned block survives without roots; unpinning releases it.
- G5: repeated allocate-and-collect cycles do not leak.
- G6: a program that allocates a vector, a string and a map on
  every iteration of a 20,000-step loop, run on a VM under
  `GcPolicy.stress`, computes the exact total and keeps
  `Heap.peak_live_bytes` within a fixed budget above what bootstrap
  left live; G6b builds closures, strings and vectors across many
  cycles and reads them back intact.

`test/prop/heap.zig` (H2, H3, H6) drives `sweepUnmarked` directly
with mark bits set by hand; it tests the sweep primitive, not the
collector. `test/prop/transient.zig` T4/T4b collect with a transient
wrapper as the sole root.

Under the runtime, `test/integration/eval_pipeline.zig` ("gc: …")
runs `map`, `filter`, `keep`, `map-indexed`, `mapv`, `reduce`,
`reductions`, `sort-by`, `max-key`, `repeatedly`, `iterate`,
`swap!`, `alter-meta!`, `apply`, closures over a loop,
`db/reduce-tree` and `db/alter!` with callbacks that each allocate
a few kilobytes on a VM under `GcPolicy.stress`, asserting the
results and that cycles ran; `test/nextomic/gc.nx` does the same
through `bin/nexis` with `NEXIS_GC_STRESS=1` for a `q` predicate, a
function binding and a custom aggregate. `NEXIS_GC_STRESS=1 zig
build test` runs the whole suite with every VM under the stress
policy.

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
└─ @import("nextomic_handle")  — nextomic_handle.traceEntity (the conn and db boxes are leaves)
```

No heap-kind module imports `gc.zig`; `vm.zig` does, as the host
(`Collector.Host`), and nothing below `vm` does. Per-kind modules
receive the visitor as `anytype`; `gc.Collector` satisfies the
duck-typed interface (`markValue`, `mark`, `markInternal`).

---

### 11.5 The rooting rule for natives

A native fn's arguments are rooted for its whole call (§3) and
`Heap.alloc` never collects (§7), so the only hazard is a heap
Value the native holds in a Zig local across a call back into the
VM after the value stopped being reachable from a root. The rule
each native follows, in order of what it is holding:

1. **An argument, or anything reachable from one** — nothing to do.
   `fnStr`, `fnSubs`, the `nexis.string` fns, the printers,
   `buildListFromSlice`, `fnSwapValsBang` (its `[old new]` vector is
   built after the callback with no safe point in between) and every
   native that never calls back in are in this class.
2. **The next callback's argument** — nothing to do: `callValue`
   roots it for the call. `fnReduce`, `fnReduceKv`, `fnSwapBang`,
   `fnDbAlter`, `fnDbReduceTree`, `fnAlterMeta` and the Nextomic
   `with` native hold only this.
3. **Callback results kept across further callbacks** — a
   `RootScope` pushes each one: `mapInto` (`map`, `mapv`, `mapcat`),
   `sieveInto` in `keep` mode, `indexedMap`,
   `fnReductions`, `repeatInto` (`repeatedly`, `iterate`),
   `keyExtremum`, `sortImpl` when a key fn is given, and the
   `nextomic/q` hook for every user-function result and every heap
   value the query pipeline builds (a tuple or full-text result bound
   as one value, an aggregate's vector or set).
4. **Values a native builds and keeps across callbacks** — no
   argument reaches them: a map entry `[k v]` or a boxed
   typed-vector element an iterator produces. Natives walk such
   receivers with `rootedSeqIter`, which roots each element it
   builds (`filter`, `remove`, `filterv`, `take-while`,
   `drop-while`, `reductions`, `sort`, `sort-by`).

A new native that calls back into the VM states which class it is
in next to its `callValue`.

**Routine constant pools.** String and bignum literals lower to
heap Values in `Routine.consts` (`compile.zig` allocates them on
`registry.heap`, the VM's heap). They are rooted through every
frame running the routine and every closure over it, recursively
through the routines nested in the pool (§3), so a literal lives as
long as any code that can load it and no longer.

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
  do not trigger GC (PLAN §10.6): the only safe point is the VM's
  instruction fetch (§7).
