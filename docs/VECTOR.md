## VECTOR.md — Persistent Vector Heap Kind

The contract for the `persistent_vector` heap kind
(`src/coll/vector.zig`): a plain 32-way radix trie plus a separate tail
node, no RRB relaxation (PLAN §23 #30). Kind number: `docs/VALUE.md`
§2.2. Header bits: `docs/HEAP.md`. Equality category and hash domain:
`docs/SEMANTICS.md` §3.3. Serializable: `docs/CODEC.md` §3.

---

### 1. Scope

The module provides construction, `conj`, `assoc`, `pop`, `nth`,
`count`, a streaming cursor, and the per-kind hash and equality entry
points. Costs:

| Operation | Cost |
|---|---|
| `nth`, `assoc` | O(log₃₂ n) path copy; O(1) in the tail |
| `conj` | O(1) amortized: a new root, and the tail's next slot claimed or the tail copied with room to grow (§2); promotes a full tail into the trie, grows the root shift at capacity |
| `pop` | O(1) while the tail holds more than one element; O(log₃₂ n) when the trie's last leaf becomes the tail |
| `fromSlice` | O(n), bottom-up, one allocation per node |
| `count`, `isEmpty` | O(1) |

The language surface lives in `src/stdlib.zig`: `vector`, `vec`, `conj`,
`assoc` (an index up to the count; one past the end appends; beyond is
`:index-out-of-bounds`), `nth` (out of range is `:index-out-of-bounds`,
or the default), `get` (nil out of range), `peek` (nil on empty), `pop`
(`vector.pop`; the empty vector is `:index-out-of-bounds`), `subvec`
(copies `end - start` elements into a fresh vector with `fromSlice`,
O(end - start); bounds outside `0..count` are `:index-out-of-bounds`, a
non-vector is `:kind-mismatch`), and invocation `([1 2 3] 1)`. `seq`,
`rest`, `next` and `nthrest` of a vector are an O(1) list view
(`docs/LIST.md` §1). `conj`, `assoc` and `pop` return a vector carrying
the argument's metadata (SEMANTICS §7).

**Absent.** RRB relaxation and O(1) `subvec`/`concat` (PLAN §23 #30);
the small-vector inline form (subkind 0, reserved).

---

### 2. Node roles

Every vector Value is subkind 1 (`subkind_root`). A vector is built from
four node roles, all `.persistent_vector` heap blocks. The role is not
recorded anywhere: every access, the GC trace included, derives it from
structural context (the root's `shift` and the descent level). The
names are conceptual labels.

| Role | Body |
|---|---|
| root | the user-facing Value: the 32-byte root body (§3) |
| interior | `[32]?*HeapHeader` child pointers, 256 bytes |
| leaf | exactly `[32]Value`, 512 bytes; always full |
| tail | `len` Values, `1 ≤ len ≤ 32`, in a block with room for `len` or more |

Only the root flows through dispatch. A leaf and a full tail share one
layout, so one node can serve both roles: `conj` promotes a full tail
into the trie as it stands, and `pop` makes the trie's last leaf the
new tail. A node reachable twice this way is traced once. Every access
reads a node's shape from the root and the descent, never from the
block's size: the tail's length is the root's `tail_len`.

**Tail claims.** Vectors may share a tail node, each using its own
`tail_len` of it. A tail's claimed length, six bits of its header's
`hash` field (`docs/HEAP.md` §1), is a length no vector sharing it
uses a slot past. `conj` onto a vector whose tail has room past its
elements and whose claimed length is its `tail_len` claims the next
slot: it writes the element there, advances the claim and shares the
node with the new vector, so the source never sees the slot. Any other
`conj` copies the tail into a block with room for the next power of
two elements, claimed at the new length: a vector grown by `conj`
copies its tail at lengths 1, 2, 3, 5, 9 and 17 and once per 32 after
its first leaf, whose tails start with room for 32. `fromSlice`,
`assoc` and `pop` build tails of exactly their length, which take no
claim, and a tail a transient owns claims nothing. A claimed slot that
a discarded vector wrote keeps its value alive as long as the node
lives: the collector marks every slot of a tail's block (GC.md §5).

---

### 3. Root body layout

| Offset | Field | Meaning |
|---|---|---|
| 0 | `count: u32` | element count, tail included |
| 4 | `shift: u32` | root trie shift: 0 when `count ≤ 32`, 5 for a root whose children are leaves, 10, 15, … |
| 8 | `root_node: ?*HeapHeader` | an interior node; null when `count ≤ 32` |
| 16 | `tail_node: ?*HeapHeader` | null only when `count == 0` |
| 24 | `tail_len: u32` | 0..32 |
| 28 | `_pad: u32` | layout only; never hashed or compared |

**Invariants** (every live vector satisfies all):

1. `count == 0`: `shift == 0`, both nodes null, `tail_len == 0`.
2. `0 < count ≤ 32`: `shift == 0`, `root_node == null`, `tail_len == count`.
3. `count > 32`: `root_node != null`, `1 ≤ tail_len ≤ 32`, and `shift` is
   the smallest multiple of 5 (≥ 5) with `count - tail_len ≤ 32 << shift`.
4. `tail_offset = count - tail_len`: index `i < tail_offset` lives in the
   trie, `i ≥ tail_offset` in the tail at `i - tail_offset`.
   `tail_len` is the authority; `count % 32` misreports a full tail.
5. Interior children are non-null exactly in a populated prefix of
   their slots. The shape is a function of the count: `conj`, `pop` and
   `fromSlice` build the same trie for the same elements.
6. Leaves hold exactly 32 Values; only the tail is partial.
7. Only the root carries metadata (the header's `meta` slot,
   SEMANTICS §7); interior, leaf and tail nodes never do, so the
   collector's `markInternal` skips their meta.

Trie boundaries follow from invariant 3: 33 elements give the first
leaf (shift 5); 1056 fills a shift-5 trie (1024 + a full tail); 1057
grows the shift to 10; 32800 fills it; 32801 grows it to 15.

---

### 4. Cursor

`Cursor.init(v)` walks from the first element, `Cursor.initAt(v,
start)` from element `start` (a list view's walk, `docs/LIST.md` §1);
`next()` returns the next element or null. The cursor holds the leaf or
tail the next index lies in and descends the trie again only when it
crosses into the next 32-element chunk, so a whole walk is O(n).
`hashSeq`, `equalSeq`, `dispatch`'s list-against-vector walk and the
stdlib's sequence iterator use it. It is internal, not a language API.

---

### 5. Public API (`src/coll/vector.zig`)

| Function | Contract |
|---|---|
| `empty(heap) !Value` | the empty vector |
| `fromSlice(heap, elems) !Value` | in natural order, the shape a left fold of `conj` gives |
| `conj(heap, v, elem) !Value` | append |
| `assoc(heap, v, i, elem) !Value` | `i < count(v)` |
| `pop(heap, v) !Value` | `v` non-empty; a one-element vector pops to the empty vector |
| `count(v) usize`, `isEmpty(v) bool` | |
| `nth(v, i) Value` | panics in safe builds out of bounds |
| `hashSeq(h, elementHash) u64` | §7 |
| `equalSeq(a, b, elementEq) bool` | §7; takes root headers |
| `Cursor` | §4 |
| `valueFromVectorHeader(h) Value` | the Value for a root header (the transient seam, `docs/TRANSIENT.md` §8) |
| `copyRoot(heap, h)` | a copy of a root, without metadata, for a transient to own |
| `conjInPlace(heap, root, elem, edit)`, `assocInPlace(heap, root, i, elem, edit)`, `popInPlace(heap, root, edit)` | the edits of a transient that owns `root` (`docs/TRANSIENT.md` §1): they write the root and the nodes whose header `hash` is `edit` in place, copy any other node on the path once, stamping the copy, and give the shape `conj`, `assoc` and `pop` give; an owned tail grows as `conj` grows a copied one (§2), and `pop` lets go of the element it drops |
| `openTailInPlace(heap, root, edit) *[32]Value`, `closeTailInPlace(root, len)` | a builder's 32 `conjInPlace`s: for a root the edit owns whose tail is full, the tail joins the trie and a new owned tail's 32 slots, counted, are returned to be written in order; before the vector is read, `closeTailInPlace` sets the tail's length to `len` (1–32). A value in an open slot is reached by the collector at once, which marks every slot of a tail's block (§2) |
| `trace(h, visitor)` | GC trace (`docs/GC.md` §5) |

`vector.zig` never imports `dispatch`: element hashing and comparison
arrive as function-pointer callbacks.

---

### 6. Implementation traps

- **Tail promotion.** A `conj` onto a full tail pushes the tail into the
  trie as a leaf at index `tail_offset` (not `count - 1`) and starts a
  new one-element tail.
- **Claims.** A claim is safe only when the claimed length equals the
  source's `tail_len`: a larger one means another vector uses the slot.
  A tail's trace marks its whole block, never `tail_len` of it: a
  node marked through one vector is not traced again for another that
  shares it with more elements.
- **Shift growth.** When the promoted leaf needs a new trie level, a new
  root interior holds the old root in slot 0 and the path to the leaf
  in slot 1; `shift` grows by 5.
- **`nth` path.** In the trie, the child at each level is
  `(i >> level_shift) & 0x1F`, down to the leaf's `i & 0x1F`.
- **`pop` into the trie.** A one-element tail pops to the trie's last
  leaf as the new 32-element tail. The leaf's path is removed: an
  interior left empty is dropped, and a root at shift ≥ 10 left with
  only child 0 is replaced by it (the shift drops by 5), which is the
  shape `fromSlice` builds for the remaining elements.

---

### 7. Hash and equality

**Hash.** `hashSeq` is the ordered combine over index order 0..count-1
(`hash.ordered_init`, `combineOrdered`, `finalizeOrdered(acc, count)`),
truncated to `u32`: the same arithmetic as `list.hashSeq`, so equal
element sequences give the same base and, after the shared sequential
domain byte, `(hash '(1 2 3))` equals `(hash [1 2 3])`. The first call
caches a nonzero result in the root header (SEMANTICS §3.1), so a
vector used as a map key is hashed once.

**Equality.** Two vectors: `equalSeq` checks counts, then walks both
cursors in lock step through `elementEq`. A list against a vector:
`dispatch` walks a list cursor and a vector cursor in lock step. Nested
sequentials compare by category at every level: `[1 (2 3) 4]` and
`(1 [2 3] 4)` are `=` and hash alike (PLAN §23 #36).

**Tests.** `test/prop/vector.zig`: V1 `fromSlice`/`nth` round-trip;
V2 `conj` against `fromSlice`; V2b random `conj`/`assoc`/`pop` walks
against a model across the 32, 1056 and 32800 boundaries; V3 list and
vector equal and hash-equal; V4 equivalence laws; V5 `=` implies equal
hash; V6 never equal to a non-sequential value; V7 length
discrimination; V8 nested vectors; V9 cross-kind equality and hash at
the boundary sizes 33 through 32801; V10 branching histories (`conj`,
`assoc` and `pop` from random earlier versions, so versions share
tails and claim slots, with heap elements and collections in between)
keep every version's elements. Unit tests in `vector.zig` cover `pop`
shapes node for node against `fromSlice`, and a claim and the copy
that follows a second `conj` from one vector.
