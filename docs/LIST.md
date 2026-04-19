## LIST.md — Immutable Cons List Heap Kind (Phase 1)

**Status**: Phase 1 deliverable. Authoritative body-layout and API contract for
the `list` heap kind (singly-linked immutable cons list). Derivative from
`PLAN.md` §9.3, `docs/VALUE.md` §2.2, `docs/SEMANTICS.md` §2.6 / §3.2, and
`docs/HEAP.md`.

This is the second heap kind to land, and the first **collection** kind. It
therefore exercises two new pieces of runtime machinery for the first time:

1. **Function-pointer plumbing** for per-kind operations that recursively
   hash or compare arbitrary elements. `list.zig` stays out of the dispatch
   import graph; the dispatcher passes `&dispatch.hashValue` and
   `&dispatch.equal` into `hashSeq` / `equalSeq` at the kind-switch.
2. **Equality-category hashing.** Sequential collections (list, future
   persistent-vector / lazy-seq / cons) share one hash domain byte so cross-
   type equality `(= (list 1 2 3) [1 2 3])` survives the final
   `mixKindDomain` step. Pinned in `docs/SEMANTICS.md` §3.2 (amended this
   commit).

---

### 1. Scope

v1 ships both subkinds defined in VALUE.md §2.2:

- **Subkind 0 — cons.** Body is exactly `{ head: Value, tail: Value }` =
  32 bytes. The `tail` is always a `.list`-kind Value (proper lists
  only; improper / dotted pairs are rejected at `cons`).
- **Subkind 1 — empty.** Body size 0. `kind = .list, subkind = 1` is the
  empty list.

v1 does **not** share an empty-list singleton across allocations — each
`empty(heap)` call produces a fresh `*HeapHeader`. Two empty lists are
always `=` (they have the same byte content: zero bytes); `identical?`
distinguishes them by address. Shared-singleton pinning is a Phase 6
allocator optimization, tracked but not scheduled.

v1 does **not** cache `count`. List is reader / macros material per
PLAN §9.3; user code uses vectors for large sequences. If a benchmark
surfaces hot `count` on long lists, Phase 6 adds a cached `u32` to the
cons body.

---

### 2. Frozen invariants

1. **Body layout (cons, subkind 0).** Exactly 32 bytes:
   - offset 0: `head: Value` (any Kind including another list)
   - offset 16: `tail: Value` — must have `kind == .list`
2. **Empty list (subkind 1).** Body size 0. The Value's subkind byte is
   the sole discriminator; there are no heap-level fields to consult
   beyond the HeapHeader.
3. **Proper lists only.** `cons(heap, head, tail)` returns
   `error.InvalidListTail` if `tail.kind() != .list`. Propagation
   ensures that walking a cons chain never encounters a non-list
   tail. Safe-build code asserts this on every traversal step as
   defense-in-depth.
4. **Structural equality** (SEMANTICS §2.6). Two lists are `=` iff
   they have the same length and every paired element is `=`. Empty
   lists are `=` to other empty lists. Empty list `≠` nil.
5. **Hash** (SEMANTICS §3.2). `list.hashSeq(h, hasher)` returns the
   sequential ordered combine: `acc = ordered_init; for each x:
   acc = combineOrdered(acc, hasher(x)); return finalizeOrdered(acc,
   count)`. The `hasher` parameter is the dispatcher's
   `&dispatch.hashValue` — already fully mixed per-kind. The returned
   `u64` is the pre-domain base; `dispatch.hashValue` applies the
   **sequential-category** domain byte on the way out.
6. **Metadata** (SEMANTICS §7). Lists can carry metadata via
   `with-meta` once the language surface supports it; the
   `HeapHeader.meta` slot is the storage. Not used operationally
   until `with-meta` lands.

---

### 3. Public API

Lives in `src/coll/list.zig`.

```zig
/// Allocate a fresh empty list on the heap. Returns a Value with
/// kind = .list, subkind = 1. Not a shared singleton — every call
/// produces a distinct *HeapHeader.
pub fn empty(heap: *Heap) !value.Value;

/// Prepend `head` to `tail`, returning a fresh cons cell. `tail`
/// must have kind = .list (any subkind); otherwise
/// `error.InvalidListTail` is returned.
pub fn cons(heap: *Heap, head: value.Value, tail: value.Value) !value.Value;

/// Build a list from an array of Values, right-to-left. Equivalent
/// to `(foldr cons (empty) elems)`. O(n) allocations.
pub fn fromSlice(heap: *Heap, elems: []const value.Value) !value.Value;

/// True iff `v` is the empty list (kind = .list, subkind = 1).
pub fn isEmpty(v: value.Value) bool;

/// First element. Panics in safe builds if `v` is empty.
pub fn head(v: value.Value) value.Value;

/// Rest of the list (always a list Value). Panics in safe builds if
/// `v` is empty.
pub fn tail(v: value.Value) value.Value;

/// O(n) length count. No caching in v1.
pub fn count(v: value.Value) usize;

/// Per-kind hash entry point called by `dispatch.heapHashBase` with
/// the full-Value hasher as the element callback. Walks the cons
/// chain iteratively; each element's hash recurses through the
/// callback (which may itself land back here for nested lists).
/// Returns the pre-domain `u64` base; the caller applies the
/// sequential-category domain.
pub fn hashSeq(
    h: *HeapHeader,
    elementHash: *const fn (value.Value) u64,
) u64;

/// Per-kind equality entry point. Walks both cons chains in
/// lock-step, comparing each paired element via `elementEq`. Returns
/// true iff the lists have identical length and every pair is equal.
pub fn equalSeq(
    a: *HeapHeader,
    b: *HeapHeader,
    elementEq: *const fn (value.Value, value.Value) bool,
) bool;
```

**Error set.** `cons` returns `error.InvalidListTail` on non-list tail,
plus whatever `heap.alloc` returns (OOM, Overflow). `empty` and
`fromSlice` return `heap.alloc` errors.

**Panic contracts.** `head(empty)` and `tail(empty)` panic in safe
builds — they represent a caller bug (should have checked `isEmpty`
first). The language surface will expose nil-returning variants
(`first`, `rest`) as stdlib functions layered on top.

---

### 4. Dispatch integration

`dispatch.zig` gains two pieces of machinery this commit:

1. **Sequential hash domain.** The existing `mixKindDomain(base,
   kind_byte)` call at the tail of `dispatch.hashValue` is replaced
   with `mixKindDomain(base, domainByteForKind(kind))`, where
   `domainByteForKind` returns `0xF0` for every sequential kind
   (today just `.list`) and the kind byte otherwise.
2. **Category-aware equality.** `dispatch.equal` grows an equality-
   category check: two Values whose categories match can still
   be `=` even when their kinds differ (v2+ cross-type sequential),
   while two Values whose categories differ are always `!=` without
   further dispatch. Today only `list` is sequential, so the code
   path reduces to the existing same-kind dispatch — but the shape
   is correct for when vector arrives.

---

### 5. Recursion depth

`hashSeq` and `equalSeq` iterate the **top-level** cons chain — flat
lists of any length walk in constant stack. Element-level hashing /
equality can recurse through `dispatch.hashValue` / `dispatch.equal`,
which may land back on `hashSeq` / `equalSeq` when an element is
itself a list (or later, a vector). Nested structural depth of `N`
consumes `O(N)` stack frames.

v1 does not bound this depth. Deeply nested values may overflow the
stack; actual threshold depends on OS, ABI, build mode, and frame
size. Matches Clojure, which structurally recurses through
`IHashEq`/`equiv` for the same reason. v1 does not need cycle
detection because persistent values cannot form cycles (no interior
mutability). An iterative / explicit-stack walker is a Phase 6
fallback if real workloads hit the limit.

---

### 6. Interaction with other layers

- **Value layer.** `Value.hashImmediate` is unaffected — lists are
  heap kind. Full-Value hashing goes through `dispatch.hashValue`.
- **Heap layer.** `heap.alloc(.list, 0)` → empty; `heap.alloc(.list,
  32)` → cons. Bodies get zero-initialized by the allocator; cons
  `head` / `tail` Values are overwritten inside `cons`.
- **GC (future).** When `src/gc.zig` lands, the list kind's trace
  function must visit both `head` and `tail` for cons cells; empty
  lists have no outgoing references.
- **Intern layer.** No interaction; lists hold arbitrary Values,
  intern has no notion of collection kinds.
- **Reader.** `src/reader.zig` currently emits list Forms. The
  reader→Value lifting pass (Phase 2 material) will call
  `fromSlice` / `cons` to build runtime lists from Forms.

---

### 7. What LIST.md does not cover

- **Persistent-vector** (`src/coll/rrb.zig`, kind 20). The second
  member of the sequential equality category. When it lands, the
  `equalSeq` callback pattern generalizes to a cross-kind sequential
  comparator — list-vs-vector equality reuses the same element
  callback but iterates one side via list and the other via vector.
- **Lazy-seq / cons values from `seq`.** PLAN §6.7. v1's collection
  APIs return eager vectors; lazy-seq lands in v2.
- **Destructive operations** (`set-car!` etc.). Out of scope —
  nexis lists are immutable. Transients are a v1 concept but apply
  to maps/sets/vectors, not cons lists (list updates are already
  O(1) via `cons`).
- **Print/read round-trip.** The reader already parses `(a b c)`
  into Form lists; the runtime→textual direction will reuse the
  pretty-printer when the full Value-print story lands.
