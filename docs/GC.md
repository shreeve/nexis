## GC.md — Precise Mark-Sweep Garbage Collector (Phase 1)

**Status**: Phase 1 deliverable. Authoritative contract for the v1
runtime collector. Derivative from `PLAN.md` §10, `docs/VALUE.md` §5
(mark bits), and `docs/HEAP.md` (allocator + `sweepUnmarked`
scaffold). Those documents win on conflict. Reviewed against peer-AI
turn 14.

This module realizes the mark-sweep strategy already specified in
PLAN §10 and for which every earlier heap kind has been designed
forward-compatibly. Before this commit the heap's `sweepUnmarked` was
a scaffold that required hand-marking; tests (test/prop/heap.zig GC
stress) exercised the sweep primitive directly. After this commit,
`src/gc.zig`'s `Collector.collect` drives the mark phase via precise
root enumeration and per-kind tracing, closing gate test #7's
workaround.

Scope-frozen commitment: **v1 collector is explicit-only,
non-reentrant, precise mark-sweep with caller-supplied roots.** No
auto-trigger, no allocation-threshold policy, no stack scanning, no
generational/concurrent phases, no write barriers. Each deferral is
pinned below (§9).

---

### 1. Strategy (PLAN §10.1 frozen)

**Precise, non-moving, stop-the-world mark-sweep** over the runtime
heap managed by `src/heap.zig`. Caller-supplied roots; per-kind
precise tracing. Single-isolate, single-threaded v1 makes STW
trivially correct. Non-moving simplifies interaction with intern
tables, emdb-backed byte slices, and future native handles.

Mark-sweep is the "v1 first" choice per PLAN §10.3:
  - Smaller blast radius if the collector has bugs.
  - Code is small enough to audit in one sitting.
  - Throwing away the collector and installing a generational one
    later is an isolated refactor.
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
| Literal bytes embedded in compiled code (Phase 2+) | VM loader  | NO |

The collector **does not** touch any of the "NO" categories. If a
runtime heap object points into non-collected storage (e.g. a
`symbol_meta` heap block pointing to an intern-table name slice),
the pointer is data, not a GC edge — the tracer walks the heap
block but does not follow the byte pointer into intern storage.

**Intern table trace seam.** `Interner.trace(visitor)` is a no-op in
v1 because intern-owned storage is not heap-allocated in the
HeapHeader sense. The seam is retained for API stability against a
hypothetical future in which intern entries themselves live on the
heap (not planned for v1).

---

### 3. Root model (what counts as a root)

A **root** is a `*HeapHeader` the caller declares "definitely live."
The collector marks each root and recursively traces children.
Anything unreachable from the root set, not `isPinned`, is freed.

In Phase 1 the runtime has no operational roots yet — no VM frames,
no var table, no REPL history, no open transactions, no durable-ref
handles, no dynamic-binding stack. Phase 1 roots are exclusively
**caller-supplied test fixtures**. The collector API is the same
shape the full runtime will use in Phase 2+ when those root
categories come online.

Per PLAN §10.5 the full v1 root set (reachable progressively as each
subsystem ships) is:

1. Currently-executing VM frames (slot pools, upvalue arrays, operand
   stack if any). — Phase 2
2. Isolate's var table (namespace → symbol → Var). — Phase 3
3. Intern tables (symbol, keyword, string). — v1 already via
   `Interner.trace(visitor)` seam; no-op until intern storage
   changes.
4. Dynamic-binding stack. — Phase 3
5. Pinned objects: open transactions, durable-ref handles with
   active reads. — Phase 4
6. REPL history buffer (if running interactively). — Phase 3

**`pinned` vs root.** A root is what the collector starts marking
from. A pinned block (`HeapHeader.isPinned() == true`) survives
sweep regardless of mark state, even if unreachable from any root.
Pinning is for resources the collector must not reclaim but cannot
prove reachable through normal tracing — e.g. a durable-ref holding
an open read cursor against emdb. v1 provides the bit and honors it
in `sweepUnmarked`; actual pinning call sites arrive with their
respective subsystems.

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
    /// semantics in v1. Does NOT dispatch on `h.kind` — the caller
    /// knows the structural context and will walk the payload itself.
    ///
    /// Used by `vector.trace` and `hamt.traceMap`/`traceSet` to mark
    /// trie/interior/collision nodes without needing body-shape
    /// heuristics or a subkind byte in `HeapHeader` (peer-AI turn 14
    /// recommendation: centralize mark-bit state on the collector
    /// even for internal nodes).
    pub fn markInternal(self: *Collector, h: *HeapHeader) bool;

    /// Run a full collection cycle: mark every root, then sweep
    /// unmarked. Returns the number of blocks freed.
    ///
    /// Not reentrant (peer-AI turn 14). Calling `collect` from inside
    /// a trace function or a `mark` callback panics via
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

Kind dispatch table (v1):

| Kind                  | trace function             | Walks                                       |
|-----------------------|----------------------------|---------------------------------------------|
| `.string`             | `string.trace`             | nothing (byte bodies)                       |
| `.bignum`             | `bignum.trace`             | nothing (limb bodies)                       |
| `.list`               | `list.trace`               | cons head + tail; empty-list is no-op       |
| `.persistent_vector`  | `vector.trace`             | trie (internal nodes via `markInternal`) + tail |
| `.persistent_map`     | `hamt.traceMap`            | array-map entries OR CHAMP subtree          |
| `.persistent_set`     | `hamt.traceSet`            | array-set elements OR CHAMP subtree         |
| `.byte_vector`        | *panic in v1 (unalloc)*    | — |
| `.typed_vector`       | *panic in v1 (unalloc)*    | — |
| `.function`           | *panic in v1 (unalloc)*    | — |
| `.var_`               | *panic in v1 (unalloc)*    | — |
| `.durable_ref`        | *panic in v1 (unalloc)*    | — |
| `.transient`          | *panic in v1 (unalloc)*    | — |
| `.error_`             | *panic in v1 (unalloc)*    | — |
| `.meta_symbol`        | *panic in v1 (unalloc)*    | — |

"Panic in v1 (unalloc)" means: the kind byte is reserved in VALUE.md
§2.2 but no module currently allocates blocks with that kind. The
collector panics loudly if it encounters one during `mark` because
hitting the arm implies memory corruption OR a caller-side bug
(constructed a Value with the wrong kind byte). Per peer-AI turn 14:
**panic, not silent no-op**, because a silent no-op on a kind that
SHOULD trace would create invisible retention bugs.

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
metadata-bearing in v1 (CHAMP.md §8.2 and VECTOR.md §3 both pin
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

`Heap.sweepUnmarked` already:
  - Skips pinned blocks (even if unmarked).
  - Clears `marked` on surviving blocks so the next cycle starts
    fresh.
  - Poisons freed blocks' kind bytes for double-free detection.

The collector is stateless between cycles. Each call to `collect`
starts from cleared mark bits (from the previous cycle's sweep) and
ends with cleared mark bits (from the current cycle's sweep).

---

### 8. Cycle safety

The heap kinds shipped in Phase 1 are **acyclic by construction
under normal API use** — persistent collections are immutable, so
once a node is built its children are fixed. Metadata chains today
can only point forward (from a heap object to its meta map), not
back, because nothing in v1 can mutate an existing block's meta
field after an already-reachable object has consumed it as a child.

The collector nonetheless performs mark-bit idempotence
**unconditionally** via `markHeaderOnce`: a second visit to an
already-marked node returns immediately. So any future heap kinds
or metadata graphs that CAN form cycles (Vars capturing closures
that reference the var back; user-synthesized metadata loops if the
surface language ever admits them; transient mutation during an
in-progress construction) remain safe by the same mechanism, with
no API changes.

---

### 9. Deferred, explicitly

Each of the following is v1 out-of-scope. The shape of the collector
is forward-compatible with all of them:

- **Auto-trigger.** PLAN §10.6 specifies allocation-threshold-based
  triggering (`N bytes since last collection`). v1 is explicit-only
  — callers invoke `collect` directly. Future Phase 6 work: add a
  byte counter to `Heap.alloc`, a threshold config to `Collector`,
  and an auto-invocation check inside `Heap.alloc`'s hot path.
- **Stack scanning.** Never planned for v1 per PLAN §10.5 — the VM
  is frame/slot-based and maintains its own precise root list. A
  conservative stack scanner is not required and is not added.
- **Write barriers.** Single-threaded mark-sweep has no data races
  and no generational / remembered-set concerns. Future generational
  migration (PLAN §10.3) would introduce a young-space / remembered-
  set barrier, but that's v3+ territory.
- **Concurrent / incremental GC.** Out of scope for v1 (single-
  isolate, STW is acceptable).
- **Finalizers.** Not in v1. Objects that own OS resources (open
  files, pinned durable-ref reads) are tracked separately at the
  tx/db layer via explicit close calls.
- **Transient ownership tracking by GC.** When transients land
  (`src/coll/transient.zig`), the owner-token machinery lives at the
  kind level; GC treats transients as regular heap objects (their
  `trace` walks the inner structure; their mutability is orthogonal).

---

### 10. Testing

Inline tests in `src/gc.zig` cover structural correctness:

- Empty collection (no roots): all blocks become unreachable, all
  are freed.
- Flat roots: 10 allocations, 3 passed as roots, 3 survive.
- Nested reachability: list-of-lists where only the outer list is a
  root; every inner list survives.
- Cross-kind graph: a persistent map whose values are lists of
  integers (where integers are immediates, so no additional heap
  refs). Outer map as root → map + all value-lists survive.
- Meta propagation: an object with `h.meta` non-null; meta's
  reachable closure survives.
- Cycle safety: simulated via mark-then-revisit; mark bit
  short-circuits.
- Pinned blocks survive even without being in the root set.
- Idempotence: `collect(roots)` called twice in a row; second call
  frees 0 blocks (marks clear from first call's sweep).
- Non-reentrancy: calling `collect` from inside a visitor callback
  panics.
- `markInternal` return value: true on first call, false on second.

Property tests in `test/prop/gc.zig` (new) exercise randomized
graphs per peer-AI turn 14:

- Build a graph of 50..200 heap objects (strings, lists, maps, sets,
  nested into each other randomly), maintaining a "reachable set"
  in a parallel model.
- Invoke `collect(root_set)`.
- Assert `liveCount == reachable_set.size`.
- Repeat 50 trials.

The existing `test/prop/heap.zig` gate-test #7 GC-stress property
gets upgraded: replace the hand-marking workaround with real
`Collector.collect` invocations.

---

### 11. Module graph

```
gc.zig
├─ @import("heap")          — HeapHeader + Heap + sweepUnmarked
├─ @import("value")         — Value + Kind
├─ @import("string")        — string.trace
├─ @import("bignum")        — bignum.trace
├─ @import("list")          — list.trace
├─ @import("vector")        — vector.trace
└─ @import("hamt")          — hamt.traceMap + hamt.traceSet
```

One-way terminal, same discipline as `dispatch.zig`. No heap-kind
module imports `gc.zig`. Per-kind modules receive the visitor as
`anytype`; `gc.Collector` satisfies the duck-typed interface
(`markValue`, `mark`, `markInternal`).

---

### 12. What GC.md does not cover

- **Per-kind trace implementations.** Each kind's own doc is amended
  with a short "Trace function" section describing what it walks.
  (HEAP.md / STRING.md / BIGNUM.md / LIST.md / VECTOR.md / CHAMP.md
  each gain one paragraph.)
- **Allocator internals.** HEAP.md is authoritative; the collector
  is a consumer of that API.
- **Intern table internals.** INTERN.md §5 is authoritative on the
  `trace` seam; this doc only notes the ownership boundary.
- **Codec serialization interaction.** None in v1. Codec operations
  do not trigger GC (PLAN §10.6).
