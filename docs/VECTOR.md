## VECTOR.md — Persistent Vector Heap Kind (Phase 1)

**Status**: Phase 1 deliverable. Authoritative body-layout and semantic
contract for the `persistent_vector` heap kind. Derivative from
`PLAN.md` §9.2 + §23 #30, `docs/VALUE.md` §2.2, `docs/SEMANTICS.md`
§2.6 / §3.2 (as amended in `accbb83` for shared sequential hash
domain), `docs/HEAP.md`, and `docs/LIST.md`. Those documents win on
conflict.

This is the **second sequential collection kind** and the first direct
stress test of the cross-kind sequential equality/hash story the
architecture committed to two sessions ago. It lands with:

1. A **streaming cursor abstraction** (peer-AI turn-7 review) that
   replaces the `count + nth` proposal — sequential equality across
   kinds is streaming ordered traversal, not random-access-by-index.
   This sets the pattern for lazy-seq / cons / any future sequential.
2. A **4-subkind representation** for root / interior / leaf / tail,
   each a distinct subkind within `kind = .persistent_vector`. This
   cleanly separates the "exactly 32 values" leaf invariant from the
   "0..32 values, partial" tail invariant, and gives the future GC a
   per-subkind trace dispatch.
3. The **critical cross-kind property test**: `(= (list 1 2 3) [1 2 3])`
   and `(hash (list 1 2 3)) == (hash [1 2 3])` land green. If that
   passes, the architectural composition risk peer-AI flagged as the
   primary hidden fault line is retired.

Scope-frozen commitment: **this module ships construction +
canonical trie/tail representation + core accessors + cross-kind
integration only.** `assoc`, `pop`, `subvec`, `concat`, transients,
and the small-vector-inline (subkind 0) space optimization are
deferred to later commits.

---

### 1. Scope

**In:**

- Representation: plain 32-way radix trie + separate tail node, per
  PLAN §9.2 + §23 #30. No RRB relaxation in v1.
- Construction: `empty(heap)`, `fromSlice(heap, elems)`, `conj(heap,
  v, elem)` (O(1) amortized append with automatic tail promotion and
  root-shift growth).
- Accessors: `count(v)`, `nth(v, i) Value` (O(log₃₂ n)),
  `isEmpty(v)`.
- Per-kind dispatch: `hashSeq(h, elementHash) u64` + `equalSeq(a, b,
  elementEq) bool` — same fn-pointer signatures as list for symmetry.
- Internal cursor: `Cursor` type + `cursorInit` + `cursorNext` for
  streaming ordered traversal. Consumed by `dispatch.sequentialEqual`
  to walk list↔vector pairs in lock-step.

**Out (each lives in a later commit):**

- `assoc n v` — O(log₃₂ n) path-copy update. Significant additional
  code; independent of the architectural composition story this
  commit is retiring.
- `pop` — has a non-trivial tail-promotion case when tail becomes
  empty and must be pulled up from the trie.
- `subvec`, `concat` — O(n) in v1 regardless of implementation
  choice (PLAN §9.2); not architecturally interesting.
- **Transients** — lands with the transients commit, alongside map/set
  transient support.
- **Small-vector-inline subkind 0** — space optimization; all vectors
  including the empty one use subkind 1 (root + possibly null root
  trie) for the first landing. Small-vector inline slots into subkind
  0 as a future optimization, exactly like string SSO (subkind 0 is
  reserved, subkind 1 is where v1 lives).
- **RRB relaxation** — v2+ per PLAN §23 #30, frozen decision.

---

### 2. Subkind taxonomy (four subkinds within `.persistent_vector`)

VALUE.md §2.2 names persistent_vector as kind 20 with "0 = inline
(≤32); 1 = trie + tail." This commit extends that with two internal
subkinds peer-AI turn-7 refined:

| Subkind | Name          | Role                                                       |
|---------|---------------|------------------------------------------------------------|
| 0       | reserved      | Future small-vector inline optimization; not used in v1.   |
| 1       | `root`        | The user-facing vector Value. Body = root metadata + pointers to tail and (optionally) root trie node. |
| 2       | `interior`    | Internal trie node. Body = `[32]?*HeapHeader` child pointers. |
| 3       | `leaf`        | Trie leaf node. Body = exactly `[32]Value`. Always full.   |
| 4       | `tail`        | Tail node. Body = `[0..32]Value`. Length determined by body size. |

Only subkind-1 (`root`) Values ever flow through dispatch. Subkinds
2–4 are internal allocations — the heap holds them, GC will trace
them, but they're never wrapped into user-visible `Value`s. Each
accessor safe-asserts the subkind of the header it receives.

Body-size-to-count mapping per subkind:

- `root`: 32 bytes (see §3).
- `interior`: 32 × 8 = 256 bytes.
- `leaf`: 32 × 16 = 512 bytes.
- `tail`: `len × 16` bytes where `0 ≤ len ≤ 32`. An empty-tail vector
  (count == 0) has no tail node at all; `tail_ptr` is null.

---

### 3. Root body layout (subkind 1)

```zig
const RootBody = extern struct {
    count: u32,            // total element count, including tail
    shift: u32,            // root trie shift; 0 when count ≤ 32, 5 for depth-1, 10 for depth-2, ...
    root_node: ?*HeapHeader, // root trie node (interior or leaf); null when count ≤ 32
    tail_node: ?*HeapHeader, // tail node; null only when count == 0
    tail_len: u32,         // 0..32
    _pad: u32,             // align to 8; NEVER semantic
};  // 32 bytes
```

Every vector — small, large, or empty — uses the same 32-byte root
body. `_pad` is layout-only and is never fed into hashing or
equality. The `tail_len` field is stored explicitly because
`count % 32` isn't sufficient for the small-vector case where every
element lives in the tail (e.g., `count == 5 → tail_len == 5`, not
`5 % 32 == 5` which accidentally works but `count == 32 → tail_len
== 32` with empty trie, not `0`).

**Frozen invariants** (every live vector satisfies all):

1. If `count == 0`: `shift == 0`, `root_node == null`, `tail_node == null`, `tail_len == 0`.
2. If `0 < count ≤ 32`: `shift == 0`, `root_node == null`, `tail_node != null`, `tail_len == count`.
3. If `count > 32`: `shift >= 5`, `root_node != null`, `tail_node != null`, `1 ≤ tail_len ≤ 32`.
4. Count and tail-offset relationship: `tail_offset := count - tail_len`. Every element at index `i < tail_offset` lives in the trie; every element at index `i >= tail_offset` lives in the tail at offset `i - tail_offset`.
5. Interior nodes only have non-null children in the populated prefix (canonical leftmost structure); trailing null children are fine but not required.
6. Leaves are always exactly 32 Values. Only the tail is partial.

---

### 4. Cursor abstraction (peer-AI turn-7 recommendation)

The architectural pattern for cross-kind sequential equality is
**streaming ordered traversal**, not random-access. Each sequential
kind exposes a `Cursor` whose internal state tracks current position
and whose `next()` returns the next element in logical order or
`null` when exhausted.

```zig
// vector.zig
pub const Cursor = struct {
    root: Value,   // the vector being iterated; kind asserted .persistent_vector
    index: usize,  // next element to return (0..count]

    pub fn init(v: Value) Cursor;
    pub fn next(self: *Cursor) ?Value;
};
```

For v1 the vector cursor uses `nth(v, i)` per step (O(log₃₂ n) per
call). Total list↔vector equality is O(n · log₃₂ n). A Phase 6
optimization can rewrite the cursor to track current leaf and local
offset, reducing to O(n) amortized, without changing the public
`Cursor.init` / `Cursor.next` shape.

The corresponding list cursor (landing in this commit's
`src/coll/list.zig` extension):

```zig
// list.zig
pub const Cursor = struct {
    current: Value, // always .list kind; empty => next() returns null

    pub fn init(v: Value) Cursor { return .{ .current = v }; }
    pub fn next(self: *Cursor) ?Value;  // O(1) per step
};
```

`dispatch.sequentialEqual` unions the two cursor types and walks
pairwise:

```zig
fn sequentialEqual(a: Value, b: Value) bool {
    // Same-kind fast paths (existing list-list; new vector-vector).
    if (a.kind() == .list and b.kind() == .list)
        return list.equalSeq(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &equal);
    if (a.kind() == .persistent_vector and b.kind() == .persistent_vector)
        return vector.equalSeq(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &equal);

    // Cross-kind: cursor walk.
    var ca = seqCursorInit(a);
    var cb = seqCursorInit(b);
    while (true) {
        const na = seqCursorNext(&ca);
        const nb = seqCursorNext(&cb);
        if (na == null and nb == null) return true;
        if (na == null or nb == null) return false;
        if (!equal(na.?, nb.?)) return false;
    }
}
```

Where `seqCursorInit(v)` returns a union-of-cursors dispatching on
`v.kind()`. The cursor pattern is **not** exposed as a public
language-level API in v1 — it's an internal composition tool for
dispatch. A user-facing `seq` abstraction is PLAN §6.7 / Phase 3
work.

---

### 5. Public API

Lives in `src/coll/rrb.zig` (named for historical reasons; the v1
impl is plain trie, not RRB, per PLAN §23 #30).

```zig
pub fn empty(heap: *Heap) !value.Value;
pub fn fromSlice(heap: *Heap, elems: []const value.Value) !value.Value;
pub fn conj(heap: *Heap, v: value.Value, elem: value.Value) !value.Value;

pub fn count(v: value.Value) usize;
pub fn isEmpty(v: value.Value) bool;

/// Element access. Panics in safe builds on out-of-bounds.
pub fn nth(v: value.Value, i: usize) value.Value;

/// Per-kind dispatch entry points. Both funneled from dispatch.zig.
pub fn hashSeq(h: *HeapHeader, elementHash: *const fn (value.Value) u64) u64;
pub fn equalSeq(a: *HeapHeader, b: *HeapHeader, elementEq: *const fn (value.Value, value.Value) bool) bool;

/// Streaming cursor for cross-kind walking. dispatch.sequentialEqual
/// composes list.Cursor and vector.Cursor into a union.
pub const Cursor = struct { ... };
```

---

### 6. Implementation traps (peer-AI turn-7 catalogue)

Each of these is a classic Clojure-PersistentVector implementer
misstep; the impl + tests must cover all of them explicitly.

- **Full-tail promotion during `conj`.** When the tail is already 32
  elements, appending pushes the old tail into the trie as a leaf
  node and starts a new tail with just the appended element. Easy
  off-by-one: use `tail_offset = count - tail_len` (NOT `count - 1`)
  as the index at which the tail's elements live, which is the base
  for trie-path calculation.
- **Shift growth at capacity overflow.** When the existing trie can't
  hold another promoted leaf at the current `shift` (i.e., the
  promoted leaf index would require a new trie level), allocate a
  new root interior node with the old root in slot 0 and a path to
  the promoted leaf in slot 1, increment `shift` by 5.
- **Path calculation for `nth`.** If `i >= count - tail_len`, read
  from tail at offset `i - tail_offset`. Else descend the trie: at
  each level with current `level_shift`, child index is
  `(i >> level_shift) & 0x1F`; decrease `level_shift` by 5 until
  `level_shift == 0`, then read the leaf's element at index `i & 0x1F`.
- **Structural invariants on leaf vs tail.** Leaves (subkind 3) are
  always exactly 32 Values; tail (subkind 4) is the ONLY partial
  node. Mixing these breaks the trie path arithmetic.
- **`tail_len` is the authority.** Do not derive tail length from
  `count % 32` — it's wrong for the boundary case `count == 32` (tail
  is full, not empty).

---

### 7. Hash and equality contract

**Hash.** `vector.hashSeq` produces the same pre-mix `u64` base as
`list.hashSeq` for equal element sequences, because both use
identical `hash.ordered_init`, `hash.combineOrdered`, and
`hash.finalizeOrdered(h, count)` arithmetic. `dispatch.hashValue`
then applies `mixKindDomain(base, sequential_domain_byte)` =
`mixKindDomain(base, 0xF0)`, which is the shared sequential-category
byte. Result: `(hash (list 1 2 3)) == (hash [1 2 3])` by
construction.

Traversal order in `hashSeq`: logical index 0..count-1. That means
trie leaves in ascending key order, then tail in order. Matches list
head→tail order.

**Equality.** Same-kind vector-vector equality via `vector.equalSeq`
walks both structures in lock-step (count check first; then
element-wise via the `elementEq` callback, same pattern as list).
Cross-kind list↔vector via `dispatch.sequentialEqual`'s cursor walk
(§4).

The cross-kind invariant test is the single most important
correctness artifact of this commit: if `(list 1 2 3)` and
`[1 2 3]` are `=` AND share `hashValue`, the sequential-category
architecture works end-to-end. If either fails, something in the
hash-domain mixing, the cursor walk, or the finalizeOrdered call is
wrong.

---

### 8. Integration with dispatch.zig

The heap-kind switch in `heapHashBase` gains
`.persistent_vector => vector.hashSeq(h, &hashValue)`. The kind-local
`heapEqual` switch never routes to vector because vector is
sequential-category; `dispatch.sequentialEqual` handles it.

`dispatch.sequentialEqual` is rewritten to the cursor-walk shape
above. The existing list-list fast-path stays (O(n) via
`list.equalSeq`); the new vector-vector fast-path uses
`vector.equalSeq`. Cross-kind pairs fall through to cursor-walk.

`dispatch.zig` now imports `vector` (`@import("coll/rrb")` via the
`vector_mod` build wiring). Since dispatch is already a one-way
terminal depending on every heap kind, this is additive.

---

### 9. Testing strategy

**The cross-kind invariant test** (the commit's retirement receipt
for peer-AI's #1 hidden fault line):

```zig
test "cross-kind: (list 1 2 3) and [1 2 3] are = and share hashValue" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const elems = [_]Value{ fx(1), fx(2), fx(3) };
    const l = try list.fromSlice(&heap, &elems);
    const v = try vector.fromSlice(&heap, &elems);
    try testing.expect(dispatch.equal(l, v));
    try testing.expectEqual(dispatch.hashValue(l), dispatch.hashValue(v));
}
```

**Boundary tests at structural cliff edges.** The trie grows /
promotes at specific counts; each must be tested for `count`, `nth`
over all indices, `fromSlice` round-trip, `conj` progression, and
list/vector cross-kind equality:

- 0 (empty)
- 1 (one tail element, empty trie)
- 31 (tail almost full)
- 32 (tail exactly full, empty trie)
- 33 (first trie promotion; trie has one leaf)
- 1024 (trie depth 1 exactly full; shift = 5)
- 1025 (trie depth 2 begins; shift grows to 10)
- 32768 (trie depth 2 exactly full; shift = 10)
- 32769 (trie depth 3 begins; shift grows to 15)

**Property tests** (`test/prop/vector.zig`) over random sequences:

- V1. `fromSlice` + `nth(i)` round-trip byte-exact over 200 random sizes.
- V2. `conj` preserves the sequence: `fromSlice(&elems)` equals
  `elems.reduce(conj, empty)` by structure and hash.
- V3. Cross-kind: random element sequences produce `=` and
  `hashValue`-equal list and vector Values. 500+ iterations.
- V4. Equivalence laws on vectors: reflexive, symmetric, transitive
  `equal` over a pool of 32 random vectors.
- V5. Bedrock `equal ⇒ hashValue equal` over 500 random vector pairs
  built from identical sequences in different allocations.
- V6. Cross-kind never-equal: a vector is never `=` to any
  non-sequential Value; hashes differ.
- V7. Length discrimination: differing lengths break equality.
- V8. Nested vectors recurse through dispatch (vector-of-vector).
- V9. Mixed cross-kind nested: `[1 (2 3) 4]` vs `(1 [2 3] 4)` — should
  NOT be equal because element 1 is a list in one and a vector in the
  other (cross-kind at the element level).

---

### 10. What VECTOR.md does not cover

- **`assoc n v`, `pop`, `subvec`, `concat`** — each lands in its own
  commit with its own invariants.
- **Transients** — lands with the transients module alongside map/set.
- **RRB relaxation** — v2+ per PLAN §23 #30.
- **Small-vector inline (subkind 0)** — Phase 6 space optimization.
- **Language-surface `seq` API** — PLAN §6.7 / Phase 3.
- **Iteration in user code** — user-facing iteration via `map`,
  `reduce`, `for`, etc. lives in stdlib macros / core.nx (Phase 3).
- **Print/read round-trip for vectors** — reader already parses
  `[1 2 3]`; the runtime → textual direction reuses the pretty-printer
  when the full Value-print story lands.
