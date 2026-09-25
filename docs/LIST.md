## LIST.md — Immutable List Heap Kind

Authoritative body-layout and API contract for
the `list` heap kind: singly-linked immutable cons cells, and views
of a vector from an offset. Derivative from
`PLAN.md` §9.3, `docs/VALUE.md` §2.2, `docs/SEMANTICS.md` §2.6 / §3.2, and
`docs/HEAP.md`.

The list is the simplest collection kind and carries two pieces of runtime
machinery every collection shares:

1. **Function-pointer plumbing** for per-kind operations that recursively
   hash or compare arbitrary elements. `list.zig` stays out of the dispatch
   import graph; the dispatcher passes `&dispatch.hashValue` and
   `&dispatch.equal` into `hashSeq` / `equalSeq` at the kind-switch.
2. **Equality-category hashing.** Sequential collections (list and
   persistent vector) share one hash domain byte so cross-type equality
   `(= (list 1 2 3) [1 2 3])` survives the final `mixKindDomain` step.
   Pinned in `docs/SEMANTICS.md` §3.2.

---

### 1. Scope

The list kind has three subkinds:

- **Subkind 0 — cons.** Body is exactly `{ head: Value, tail: Value }` =
  32 bytes. The `tail` is always a `.list`-kind Value (proper lists
  only; improper / dotted pairs are rejected at `cons`).
- **Subkind 1 — empty.** Body size 0. `kind = .list, subkind = 1` is the
  empty list.
- **Subkind 2 — vector view.** Body is one Value, a persistent vector
  = 16 bytes. The Value's tag bits 32..63 hold an offset (a `u32`, as
  a vector's count is): the view is the vector's elements from that
  offset on, empty when the offset equals the count. `seq`, `rest`,
  `next`, `nthrest`, `nthnext` and `drop` of a vector make one view
  block (O(1) whatever the length); `tail` and `drop` of a view return
  the same block at a later offset and allocate nothing, which is why
  the offset lives in the Value rather than the block. `head` is the
  vector's `nth` (O(log₃₂ n)), `count` is `count - offset`, and the
  cursor walks the vector's leaves directly.

A view is a list to every consumer: it is `seq?`, prints as `(...)`,
is `=` to and hashes as the list of the same elements, can be the tail
of a cons, and the codec encodes it as a list (decoding gives cons
cells).

There is **no** shared empty-list singleton across allocations — each
`empty(heap)` call produces a fresh `*HeapHeader`. Two empty lists are
always `=` (they have the same byte content: zero bytes); `identical?`
distinguishes them by address. There is no shared-singleton pinning.

`count` is **not** cached: O(1) for a view, O(n) over cons cells.
List is reader / macros material per PLAN §9.3; user code uses vectors
for large sequences. If a benchmark surfaces hot `count` on long lists,
a cached `u32` in the cons body is the remedy.

---

### 2. Frozen invariants

1. **Body layout (cons, subkind 0).** Exactly 32 bytes:
   - offset 0: `head: Value` (any Kind including another list)
   - offset 16: `tail: Value` — must have `kind == .list`
2. **Empty list (subkind 1).** Body size 0. The Value's subkind byte is
   the sole discriminator; there are no heap-level fields to consult
   beyond the HeapHeader. `isEmpty` is also true of a view whose
   offset equals its vector's count.
2a. **View (subkind 2).** Body exactly 16 bytes: the vector Value. The
   offset is in the Value's tag, never in the block, and is at most
   the vector's count. Body sizes 0, 16 and 32 are distinct, so the
   collector tells the three apart from the block alone.
3. **Proper lists only.** `cons(heap, head, tail)` returns
   `error.InvalidListTail` if `tail.kind() != .list`. Propagation
   ensures that walking a cons chain never encounters a non-list
   tail. Safe-build code asserts this on every traversal step as
   defense-in-depth.
4. **Structural equality** (SEMANTICS §2.6). Two lists are `=` iff
   they have the same length and every paired element is `=`. Empty
   lists are `=` to other empty lists. Empty list `≠` nil.
5. **Hash** (SEMANTICS §3.2). `list.hashSeq(v, hasher)` returns the
   sequential ordered combine: `acc = ordered_init; for each x:
   acc = combineOrdered(acc, hasher(x)); return finalizeOrdered(acc,
   count)` truncated to `u32`. The `hasher` parameter is the
   dispatcher's `&dispatch.hashValue` — already fully mixed per-kind.
   The result is the pre-domain base; `dispatch.hashValue` applies the
   **sequential-category** domain byte on the way out. The first call
   caches it in the head cell's header (a computed zero is not cached;
   SEMANTICS §3.1), so a list used as a map key is hashed once. A view
   caches nothing: every offset of it shares one header.
6. **Metadata** (SEMANTICS §7). Lists carry metadata through
   `with-meta`; the `HeapHeader.meta` slot is the storage. `with-meta`
   of a view first copies its elements into cons cells, since metadata
   on the shared view block would follow `rest`; so a view's block
   never carries metadata and `(meta (seq v))` is nil whatever `v`'s
   metadata.

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

/// The elements of vector `vec` from `start` (≤ its count) on: one
/// view block.
pub fn ofVector(heap: *Heap, vec: value.Value, start: usize) !value.Value;

/// True iff `v` has no elements: the empty list, or a view at its
/// vector's end.
pub fn isEmpty(v: value.Value) bool;

/// First element. Panics in safe builds if `v` is empty.
pub fn head(v: value.Value) value.Value;

/// Rest of the list (always a list Value); never allocates. Panics
/// in safe builds if `v` is empty.
pub fn tail(v: value.Value) value.Value;

/// Length: O(1) for a view, O(n) over cons cells; nothing caches it.
pub fn count(v: value.Value) usize;

/// The list without its first `n` elements, empty when shorter;
/// never allocates, and a view moves its offset in one step.
pub fn drop(v: value.Value, n: usize) value.Value;

/// Streaming iteration: `Cursor.init(v)`, then `next()` until null.
/// On reaching a view it walks the vector's leaves directly.
pub const Cursor = struct { ... };

/// Per-kind hash entry point called by `dispatch.heapHashBase` with
/// the full-Value hasher as the element callback. Walks the cons
/// chain iteratively; each element's hash recurses through the
/// callback (which may itself land back here for nested lists).
/// Returns the pre-domain `u64` base; the caller applies the
/// sequential-category domain.
pub fn hashSeq(
    v: value.Value,
    elementHash: *const fn (value.Value) u64,
) u64;

/// Per-kind equality entry point. Walks both lists in lock-step,
/// comparing each paired element via `elementEq`. Returns true iff
/// the lists have identical length and every pair is equal.
pub fn equalSeq(
    a: value.Value,
    b: value.Value,
    elementEq: *const fn (value.Value, value.Value) bool,
) bool;
```

**Error set.** `cons` returns `error.InvalidListTail` on non-list tail,
plus whatever `heap.alloc` returns (OOM, Overflow). `empty` and
`fromSlice` return `heap.alloc` errors.

**Panic contracts.** `head(empty)` and `tail(empty)` panic in safe
builds — they represent a caller bug (should have checked `isEmpty`
first). The language surface's nil-returning `first` and `rest` are
stdlib functions layered on top.

---

### 4. Dispatch integration

`dispatch.zig` carries two pieces of machinery for it:

1. **Sequential hash domain.** `dispatch.hashValue` ends with
   `mixKindDomain(base, domainByteForKind(kind))`, where
   `domainByteForKind` returns `0xF0` for every sequential kind
   (`.list`, `.persistent_vector`) and the kind byte otherwise.
2. **Category-aware equality.** `dispatch.equal` checks the equality
   category first: two Values whose categories match can still
   be `=` even when their kinds differ (list and vector are both
   sequential), while two Values whose categories differ are always
   `!=` without further dispatch.

---

### 5. Recursion depth

`hashSeq` and `equalSeq` iterate the **top-level** cons chain — flat
lists of any length walk in constant stack. Element-level hashing /
equality can recurse through `dispatch.hashValue` / `dispatch.equal`,
which may land back on `hashSeq` / `equalSeq` when an element is
itself a list or a vector. Nested structural depth of `N`
consumes `O(N)` stack frames.

`dispatch.equal` and `dispatch.hashValue` check the stack guard at each
structural step; a value nested too deep for the stack that remains
raises the catchable `:stack-overflow` instead of faulting
(SEMANTICS §2.7). There is no cycle detection because persistent
values cannot form cycles (no interior mutability).

---

### 6. Interaction with other layers

- **Value layer.** `Value.hashImmediate` is unaffected — lists are
  heap kind. Full-Value hashing goes through `dispatch.hashValue`.
- **Heap layer.** `heap.alloc(.list, 0)` → empty; `heap.alloc(.list,
  16)` → view; `heap.alloc(.list, 32)` → cons. Bodies get zero-initialized by the allocator; cons
  `head` / `tail` Values are overwritten inside `cons`.
- **GC.** `list.trace` marks every head and walks the tail chain in
  a loop (`docs/GC.md` §5); empty lists have no outgoing references; a
  view marks its whole vector (the block does not know the offset).
- **Intern layer.** No interaction; lists hold arbitrary Values,
  intern has no notion of collection kinds.
- **Reader / compiler.** `src/reader.zig` emits list Forms; quoted
  lists reach runtime through the `coll:list` opcode, which builds the
  list with `cons` (`docs/VM.md` §10.8).

---

### 7. What LIST.md does not cover

- **Persistent-vector** (`src/coll/vector.zig`, kind 20). The second
  member of the sequential equality category: `dispatch.sequentialEqual`
  compares a list against a vector element by element, iterating one
  side through the list cursor and the other through the vector's.
- **Lazy-seq.** PLAN §6.7. There is no lazy-seq; `seq` of a vector is
  the eager view of §1, of every other collection a fresh list.
- **Destructive operations** (`set-car!` etc.). Out of scope —
  nexis lists are immutable. Transients apply to maps/sets/vectors,
  not cons lists (list updates are already O(1) via `cons`).
- **Print/read round-trip.** The reader parses `(a b c)` into Form
  lists; the runtime→textual direction is `src/format.zig`.
