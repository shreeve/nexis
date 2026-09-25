## VECTOR.md — Persistent Vector Heap Kind

Authoritative body-layout and semantic contract for the `persistent_vector` heap kind. Derivative from
`PLAN.md` §9.2 + §23 #30, `docs/VALUE.md` §2.2, `docs/SEMANTICS.md`
§2.6 / §3.2 (shared sequential hash domain), `docs/HEAP.md`, and `docs/LIST.md`. Those documents win on
conflict.

This is the second sequential collection kind (after `list`) and
the direct test of the cross-kind sequential equality/hash story:

1. A **streaming cursor** — sequential equality across kinds is
   streaming ordered traversal, not random access by index.
2. A **root / interior / leaf / tail** trie representation within the
   one heap kind `.persistent_vector`: the "exactly 32 values" leaf is
   distinct from the "1..32 values" tail.
3. The **cross-kind invariant**: `(= (list 1 2 3) [1 2 3])` and
   `(hash (list 1 2 3)) == (hash [1 2 3])` hold.

**The module provides construction, the canonical trie/tail
representation, `conj`, `assoc`, `pop`, `nth`, `count`, the cursor and
cross-kind integration.** `subvec`, `concat` and the
small-vector-inline (subkind 0) space optimization do not exist;
transients wrap the persistent ops (`docs/TRANSIENT.md`).

---

### 1. Scope

**In:**

- Representation: plain 32-way radix trie + separate tail node, per
  PLAN §9.2 + §23 #30. There is no RRB relaxation.
- Construction: `empty(heap)`, `fromSlice(heap, elems)`, `conj(heap,
  v, elem)` (O(1) amortized append with automatic tail promotion and
  root-shift growth). `fromSlice` builds the trie bottom-up, one
  allocation per node, into exactly the shape a left fold of `conj`
  produces; `conj` promotes a full tail into the trie as it stands
  (a leaf and a full tail share one layout).
- Update: `assoc(heap, v, i, elem)` (O(log₃₂ n) path copy; O(1) in
  the tail) and `pop(heap, v)` (§6: O(1) while the tail holds more
  than one element, O(log₃₂ n) when the last leaf becomes the tail).
- Accessors: `count(v)`, `nth(v, i) Value` (O(log₃₂ n)),
  `isEmpty(v)`.
- Per-kind dispatch: `hashSeq(h, elementHash) u64` + `equalSeq(a, b,
  elementEq) bool` — same fn-pointer signatures as list for symmetry.
- Cursor: `Cursor.init(v)` + `next()` for streaming ordered
  traversal. Consumed by `dispatch.sequentialEqual` to walk
  list↔vector pairs in lock-step, and by `hashSeq` / `equalSeq`.

**Out:**

- `subvec`, `concat` — built in `src/stdlib.zig` from `nth` and
  `fromSlice` (O(n)).
- **Transients** — `docs/TRANSIENT.md`, alongside map/set transient
  support.
- **Small-vector-inline subkind 0** — space optimization; all vectors
  including the empty one use subkind 1 (root + possibly null root
  trie). Subkind 0 is reserved for a small-vector inline form, as
  string SSO reserves its subkind 0; every vector is subkind 1.
- **RRB relaxation** — absent per PLAN §23 #30, frozen decision.

---

### 2. Node roles

VALUE.md §2.2 names persistent_vector as kind 20 with "0 = inline
(≤32); 1 = trie + tail." Every vector Value is subkind 1; subkind 0 is
reserved for a small-vector inline form and unused.

A vector is built from four node roles, all allocated as
`.persistent_vector` heap blocks. The role is **not** recorded in the
header: every access, including the GC trace, derives it from
structural context (the root's `shift` and the descent level).

| Role       | Body                                                              |
|------------|-------------------------------------------------------------------|
| `root`     | The user-facing Value: 32-byte root metadata (§3).                |
| `interior` | `[32]?*HeapHeader` child pointers, 256 bytes.                      |
| `leaf`     | Exactly `[32]Value`, 512 bytes. Always full.                       |
| `tail`     | `[len]Value`, `len × 16` bytes, `1 ≤ len ≤ 32`.                    |

Only the root ever flows through dispatch; the other nodes are never
wrapped into user-visible Values. A leaf and a full tail share one
layout, so one node can serve both roles: `conj` promotes a full tail
into the trie as it stands, and `pop` makes the trie's last leaf the
new tail. An empty vector has no tail node; `tail_node` is null.

---

### 3. Root body layout (subkind 1)

```zig
const RootBody = extern struct {
    count: u32,            // total element count, including tail
    shift: u32,            // root trie shift; 0 when count ≤ 32, 5 for depth-1, 10 for depth-2, ...
    root_node: ?*HeapHeader, // root trie node (always an interior); null when count ≤ 32
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
3. If `count > 32`: `shift >= 5`, `root_node != null` (an interior; its children are leaves when `shift == 5`), `tail_node != null`, `1 ≤ tail_len ≤ 32`. `shift` is the smallest multiple of 5 with `count - tail_len ≤ 32 << shift`.
4. Count and tail-offset relationship: `tail_offset := count - tail_len`. Every element at index `i < tail_offset` lives in the trie; every element at index `i >= tail_offset` lives in the tail at offset `i - tail_offset`.
5. Interior nodes have non-null children exactly in a populated prefix of their slots (canonical leftmost structure). The trie of a vector is a function of its count: `conj`, `pop` and `fromSlice` all yield the same shape for the same elements.
6. Leaves are always exactly 32 Values. Only the tail is partial.

---

### 4. Cursor abstraction

The architectural pattern for cross-kind sequential equality is
**streaming ordered traversal**, not random-access. Each sequential
kind exposes a `Cursor` whose internal state tracks current position
and whose `next()` returns the next element in logical order or
`null` when exhausted.

```zig
// vector.zig
pub const Cursor = struct {
    // root header, count, next index, and the current leaf or tail
    pub fn init(v: Value) Cursor;
    pub fn next(self: *Cursor) ?Value;
};
```

The vector cursor holds the leaf (or the tail) that the next index
lies in, and descends the trie again only when it crosses into the
next 32-element chunk: O(n) for a whole walk. `hashSeq` and
`equalSeq` walk with it too.

The corresponding list cursor (`src/coll/list.zig`):

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
language-level API — it is an internal composition tool for
dispatch. The user-facing `seq` natives in `src/stdlib.zig` are
built on it (PLAN §6.7).

---

### 5. Public API

Lives in `src/coll/vector.zig` (a plain trie, not RRB, per PLAN §23
#30).

```zig
pub fn empty(heap: *Heap) !value.Value;
pub fn fromSlice(heap: *Heap, elems: []const value.Value) !value.Value;
pub fn conj(heap: *Heap, v: value.Value, elem: value.Value) !value.Value;
/// `i < count(v)`.
pub fn assoc(heap: *Heap, v: value.Value, i: usize, elem: value.Value) !value.Value;
/// `v` must not be empty.
pub fn pop(heap: *Heap, v: value.Value) !value.Value;

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

### 6. Implementation traps

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
- **Structural invariants on leaf vs tail.** Leaves are
  always exactly 32 Values; the tail is the ONLY partial
  node. Mixing these breaks the trie path arithmetic.
- **`pop` when the tail empties.** A tail of one element pops to the
  trie's last leaf as the new 32-element tail (a leaf and a full tail
  share one layout, so the node is reused as it stands). The leaf's
  path is removed from the trie: an interior left with no children is
  dropped, and a root at shift ≥ 10 left with only child 0 is replaced
  by that child, so the shift drops by 5. The result has exactly the
  shape `fromSlice` builds for the remaining elements. `pop` of a
  one-element vector is the empty vector.
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
correctness artifact of this module: if `(list 1 2 3)` and
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

`dispatch.sequentialEqual` has the cursor-walk shape above. The list-list fast-path (O(n) via
`list.equalSeq`); the new vector-vector fast-path uses
`vector.equalSeq`. Cross-kind pairs fall through to cursor-walk.

`dispatch.zig` imports `coll/vector.zig`; the vector module never
imports dispatch, so hashing and comparing elements arrive as
function-pointer callbacks.

---

### 9. Testing strategy

**The cross-kind invariant test**:

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
promotes at specific counts; each is tested for `count`, `nth`,
`fromSlice` round-trip, `conj` and `pop` progression (node for node
against the shape `fromSlice` builds), and list/vector cross-kind
equality:

- 0 (empty)
- 1 (one tail element, empty trie)
- 31, 32 (tail almost full, exactly full; empty trie)
- 33 (first trie promotion; trie has one leaf, shift 5)
- 1056 (shift-5 trie full: 1024 in the trie + 32 in the tail)
- 1057 (shift grows to 10)
- 32800 (shift-10 trie full: 32768 + 32)
- 32801 (shift grows to 15)

**Property tests** (`test/prop/vector.zig`) over random sequences:

- V1. `fromSlice` + `nth(i)` round-trip byte-exact over 200 random sizes.
- V2. `conj` preserves the sequence: `fromSlice(&elems)` equals
  `elems.reduce(conj, empty)` by structure and hash.
- V2b. Random `conj` / `assoc` / `pop` walks against a model, each
  starting just below a trie boundary (32, 1056, 32800) and crossing
  it both ways.
- V3. Cross-kind: 2000 random element sequences produce `=` and
  `hashValue`-equal list and vector Values.
- V4. Equivalence laws on vectors: reflexive, symmetric, transitive
  `equal` over a pool of 32 random vectors.
- V5. Bedrock `equal ⇒ hashValue equal` over 2000 random vector pairs
  built from identical sequences in different allocations.
- V6. Cross-kind never-equal: a vector is never `=` to any
  non-sequential Value; hashes differ.
- V7. Length discrimination: differing lengths break equality.
- V8. Nested vectors recurse through dispatch (vector-of-vector).
- V9. Cross-kind equality and hash at the boundary sizes above, up to
  a three-level trie.

---

### 10. What VECTOR.md does not cover

- **`subvec`, `concat`** — do not exist in this module.
- **Transients** — `docs/TRANSIENT.md`.
- **RRB relaxation** — absent per PLAN §23 #30.
- **Small-vector inline (subkind 0)** — reserved, no implementation.
- **Language-surface `seq` API** — PLAN §6.7; natives in
  `src/stdlib.zig`.
- **Iteration in user code** — user-facing iteration via `map`,
  `reduce`, `for`, etc. lives in `src/stdlib.zig` and
  `src/stdlib/core.nx`.
- **Print/read round-trip for vectors** — the reader parses
  `[1 2 3]`; `src/format.zig` (`formatVector`) prints it.
