## CHAMP.md — Persistent Map & Set Heap Kinds

Authoritative body-layout and semantic contract for the
`persistent_map` and `persistent_set` heap kinds, implemented in
`src/coll/champ.zig`. Derivative from `PLAN.md` §9.1 + §23 #37,
`docs/VALUE.md` §2.2, `docs/SEMANTICS.md` §2.6 / §3.2, `docs/HEAP.md`,
and the precedents set by `docs/LIST.md` and `docs/VECTOR.md`. Those
documents win on conflict.

The **algorithm is CHAMP** (Steindorfer & Vinju, OOPSLA 2015 —
separate data and node bitmaps, canonical layout), not classic
Bagwell HAMT.

This module is the sole runtime member of the **associative** and
**set** equality categories (hash-domain bytes `0xF1` and `0xF2`).
The category/domain scaffolding and exhaustive table tests in
`dispatch.zig` pin `.persistent_map` and `.persistent_set` to those
categories; this module gives them bodies. The two kinds share one
CHAMP implementation, generic over the payload: a map stores
key/value entries, a set bare keys (§11).

---

### 1. Scope

**In:**

- Representation: classic CHAMP layout — separate data and node
  bitmaps per Steindorfer & Vinju (OOPSLA 2015) — plus a flat
  array-map / array-set inline optimization for small collections.
  Collision nodes at the trie's depth limit for keys that share a
  full 32-bit hash.
- Construction: `empty`, `fromEntries` / `fromElements`, `assoc` /
  `conj`, `dissoc` / `disj`.
- Accessors: `count` (O(1)), `get` / `contains`, `isEmpty`.
- Per-kind dispatch: `hashMap` / `hashSet`, `equalMap` / `equalSet`,
  element/entry iterator for unordered hash accumulation.
- Two category-equality helpers in `dispatch.zig`: `associativeEqual`
  and `setEqualCategory`, parallel to `sequentialEqual`. (These
  handle within-category equality; each category has exactly one
  kind, so they reduce to kind-local dispatch, but the shape is the
  seam for any cross-kind associative / set member.)

**Out (owned elsewhere or absent):**

- **Transients**. Owner-token editable copies live in
  `src/coll/transient.zig` (spec: `docs/TRANSIENT.md`). CHAMP node
  layouts carry no transient-specific fields; the transient wrapper
  owns its edit state.
- `merge` / `merge-with` / `update` / `select-keys` / `zipmap` and
  other stdlib-level map operators. Those compose over `assoc` /
  `dissoc` / `get` and live in the stdlib (`src/stdlib.zig` natives
  and `src/stdlib/core.nx`).
- Set operators (`union` / `intersection` / `difference`). Not
  implemented; no stdlib binding exists for them.
- RRB-style balancing for maps. Not a thing — CHAMP is the committed
  layout. Listed here only to pre-empt the question.
- Cross-kind associative or set members. Each category has one kind;
  no sorted-map or similar kind exists. Adding one requires a spec
  amendment.

---

### 2. The three-layer canonicality model (central)

**Overclaiming canonical representation is the single most likely
spec mistake here.** The rule set below is deliberately narrower
than a naive "CHAMP guarantees a unique layout for any logical entry
set" reading of PLAN §9.1.

nexis claims canonical representation at **three distinct levels**,
each with its own scope:

#### 2.1 Array-map layer (subkind 0)

- Array-maps store up to 8 entries **in association order** as a
  representation detail.
- **Two array-maps with the same key-value set compare `=` regardless
  of entry order.** Equality is O(n²) membership comparison (n ≤ 8);
  hash uses the order-independent `hash.combineUnordered`.
- There is **no** structural / bytewise uniqueness guarantee at this
  layer. Build order leaks into representation but NOT into equality
  or hash.

#### 2.2 CHAMP node layer (subkind 1 root, subkind 2 interior)

- Within a single CHAMP node, entries and child pointers occupy
  physical array positions determined by **bitmap rank (popcount)** of
  a deterministic slot assignment. Slot assignment is derived from
  5-bit hash fragments at the node's depth. This is the CHAMP paper's
  canonicality guarantee.
- Two **CHAMP-backed maps** with the same entry set produce
  structurally-identical node trees (bitmap-equal, entry-array-equal,
  recursively). This enables bitmap-level early-exit equality on
  CHAMP-vs-CHAMP comparison.
- Promotion and splitting are deterministic — independent of insertion
  order — for every case that does NOT involve a collision node.

#### 2.3 Collision-node layer (subkind 3)

- Collision nodes hold entries whose keys share a **full 32-bit hash**
  (indexable bits exhausted). The bucket is small in expectation —
  xxHash3 collision probability is ~1-in-2³².
- **Collision nodes do NOT have canonical raw-layout equality.**
  Defining one would require a total comparator over arbitrary Values
  (sorting keys by some byte encoding), which is a huge semantic
  commitment — it entangles equality-internals with a canonical-order
  contract that would propagate into serialization, stable iteration,
  and potentially language-level ordering primitives. nexis does not
  accept that commitment.
- Collision-node equality is **semantic membership comparison**:
  same count, then every entry in `a` has an equal-keyed entry in
  `b`. O(k²) in the collision-bucket size k, which is tiny.
- Bitmap early-exit does NOT apply to collision-node payloads beyond
  trivial checks (same count, same shared 32-bit hash).

#### 2.4 Cross-subkind equality

- Two maps with the same entry set but different subkinds (e.g. an
  array-map built to 8 entries vs. a CHAMP-backed map built to 9
  entries and then reduced by one `dissoc`) compare `=` and hash
  equal.
- Equality across subkinds **cannot** use bitmap early-exit. It falls
  back to **semantic associative comparison** — count equality, then
  `∀ (k,v) ∈ a: get(b, k) == Some(v)`. Same pattern for sets via
  `contains`.
- Hash is structure-independent by construction: both paths iterate
  every entry and fold via `hash.combineUnordered` + `finalizeUnordered`
  with the same entry-hash function.

#### 2.5 Summary

| Comparison kind | Equality strategy | Hash strategy |
|---|---|---|
| array-map vs array-map | O(n²) membership | unordered combine |
| CHAMP vs CHAMP, no collision | bitmap + recursive structural | unordered combine |
| CHAMP vs CHAMP with collision | bitmap + structural above, semantic at collision node | unordered combine |
| array-map vs CHAMP (cross-subkind) | semantic associative via `get` | unordered combine |

Equal entry-sets always hash equal, regardless of which cell of the
table the pair lands in. Equality is correct in every cell; bitmap
early-exit is an **optimization** confined to the cells where
canonicality provably holds.

#### 2.6 Explicit exclusions

**Canonicality in this document refers only to CHAMP node
partitioning and bitmap-derived slot placement for non-collision
paths.** It does not imply:

- unique bytewise representation across subkinds (array-map and CHAMP
  can both represent the same logical map — they do NOT share byte
  layout),
- canonical ordering of entries inside collision nodes (no total
  comparator over arbitrary keys),
- assoc-history-independent raw shape for array-map (insertion order
  leaks into representation but not into equality or hash).

Any implementation or review claim that requires one of the above
must be read as a bug in the claim, not a property of the spec.

---

### 3. Subkind taxonomy

Per VALUE.md §2.2, `Kind.persistent_map = 18` and
`Kind.persistent_set = 19` are frozen. The subkind byte disambiguates
representation families within each kind; subkind numbering is
**parallel across both kinds** to keep dispatch and GC logic regular.

| Subkind | Map role | Set role |
|---------|---------|---------|
| 0 | array-map (inline ≤ 8 entries) | array-set (inline ≤ 8 elements) |
| 1 | CHAMP root (count + pointer to root node) | CHAMP root (count + pointer to root node) |
| 2..15 | reserved | reserved |

Only subkinds 0 and 1 exist; every map or set Value carries one of
them, and the public entry points safe-assert it. The trie's
interior nodes (§4.3) and collision nodes (§4.4) are internal
allocations of the same heap kind: the heap holds them, the GC
traces them (`traceMap` / `traceSet`), but no Value points at one
and no header records which one a node is. Every walk knows from
the shift it reached a node at: past `MAX_TRIE_SHIFT` it is a
collision node, otherwise an interior. A root header's subkind is
recoverable from its body size alone (a CHAMP root body is 16 bytes,
which no array body `8 + n·32` / `8 + n·16` can be), which is how
`hashMap` / `equalMap` / `traceMap` read a bare header.

**Empty collections.** A fresh empty map is `subkind = 0, count = 0`
(a zero-entry array-map). Same for sets. Per the list / vector
precedent, empty collections are **not** a shared singleton — each
`empty(heap)` call allocates a fresh header. There is no pinned
shared-empty singleton.

---

### 4. Body layouts

Values are little-endian 64-bit. All pointers are `*HeapHeader` =
16-byte-aligned. All bodies obey HEAP.md's "zero-initialized on
allocation" rule; constructor code overwrites the fields it owns.

#### 4.1 Array-map / array-set body (subkind 0)

```zig
// Map: 8 bytes of header + count * 32 bytes of (key, value) pairs
const ArrayMapBody = extern struct {
    count: u32,   // 0..8
    _pad: u32,
    // followed by: [count] entry pairs of { key: Value, value: Value }
};

// Set: 8 bytes of header + count * 16 bytes of keys
const ArraySetBody = extern struct {
    count: u32,   // 0..8
    _pad: u32,
    // followed by: [count] element Values
};
```

- `count` ∈ [0, 8]. On the 9th insert, promotion to subkind 1 (CHAMP)
  fires — see §5.3.
- Entries / elements are stored in **association order** (insertion
  order, with replace-value updating in place). This ordering is a
  representation detail, NOT a semantic commitment — equality and
  hash ignore it.
- `_pad` bytes are never fed into hash or equality (the same
  discipline as `bignum.zig`: layout detail must not leak into hash
  output).
- Empty array-map / array-set: body size = 8 bytes; no trailing
  entries.

#### 4.2 CHAMP root body (subkind 1)

```zig
const RootBody = extern struct {
    count: u32,                  // total entries across the whole trie
    _pad: u32,
    root_node: *HeapHeader,      // always an interior node (§4.3)
};  // 16 bytes
```

- Always has a non-null `root_node` — an empty collection lives in
  subkind 0 (array-map/set with count 0), never in subkind 1.
- `count` is the authoritative total; it makes `count(v)` O(1) for
  user code and means interior nodes do NOT need to cache subtree
  counts. `assoc` reports through its recursion whether it added a
  key, and the root adjusts its count at the outer layer (Clojure's
  pattern; simpler than per-node count caching).
- `_pad` same semantic rules as above.

#### 4.3 CHAMP interior node

```zig
const InteriorHeader = extern struct {
    data_bitmap: u32,    // bit i set ⇒ slot i holds an inline entry
    node_bitmap: u32,    // bit i set ⇒ slot i holds a child pointer
    // followed by a single compact payload segment:
    //   first:  popCount(data_bitmap) inline entries
    //   then:   popCount(node_bitmap) child pointers
};
```

Invariants (normative; position arithmetic in prose is illustrative,
formula authority lives in the code):

- `data_bitmap & node_bitmap == 0` — a slot holds at most one of
  {inline-entry, child-pointer}, never both.
- **Compact payload.** The node body is a contiguous segment: all
  inline entries, then all child pointers, with no gaps.
- **Entry segment order.** Inline entries are stored in **ascending
  slot-index order** (lowest slot first). For slot `i` with bit set
  in `data_bitmap`, the entry's physical index inside the entry
  segment is the number of set bits in `data_bitmap` at slots lower
  than `i`.
- **Child segment order.** Child pointers are stored in **descending
  slot-index order** (highest slot first — CHAMP paper convention;
  lets promotion append from the back without reshuffling). For slot
  `i` with bit set in `node_bitmap`, the child's physical index
  inside the child segment is the number of set bits in `node_bitmap`
  at slots greater than `i`, counting from the top of the segment.
- **No empty interior nodes.** An interior node with zero entries
  and zero children cannot exist — that state collapses to the
  parent-level representation (either an empty subkind-0 at the
  root, or an empty slot at an ancestor node).
- **No lonely interior nodes below the CHAMP root's `root_node`.**
  An interior node with exactly one entry and zero children cannot
  exist anywhere **except as a CHAMP root's `root_node` payload** —
  the entry is otherwise pulled up into the parent's data area via
  the single-entry-subtree promotion rule (§5.5). The carve-out for
  the CHAMP root's `root_node` is necessary because the no-demotion
  rule (§5.4) keeps a one-entry CHAMP as subkind-1 rather than
  demoting to array-map; that subkind-1 must hold its single entry
  somewhere, and a one-entry interior at shift 0 is the canonical
  form (§5.6).
  
  Equivalently: every node below the root holds at least two keys in
  its subtree. A node with no entries and a single child is legal
  when that child's subtree holds two or more keys (they share the
  longer hash prefix).

  Together these make the trie a function of the key set (outside
  collision nodes, §2.3): two equal CHAMP-backed maps have
  bit-identical bitmaps at every corresponding node and iterate in the
  same order. `canonicalTrie(v, elementHash)` checks every invariant
  of this section over a whole trie; the property tests assert it
  after assoc and dissoc sequences of up to 30000 keys (§12.4).
- **Entry types.** For `persistent_map`, each inline entry occupies
  32 bytes (`{ key: Value, value: Value }`). For `persistent_set`,
  each inline entry occupies 16 bytes (`key: Value`). The code module
  selects entry width by kind; bitmap semantics are identical.

The exact popcount expressions used at call sites live in
`src/coll/champ.zig` and are covered by inline unit tests.

#### 4.4 Collision node

```zig
const CollisionHeader = extern struct {
    shared_hash: u32,    // the 32-bit indexing hash every entry shares
    count: u32,          // 2..N entries
    // followed by:
    //   map: [count] { key: Value, value: Value }
    //   set: [count] Value
};
```

- `count ≥ 2` — a bucket of one is not a collision, it's an inline
  entry that belongs in the parent interior node's data area.
- `shared_hash` is specifically the 32-bit **indexing hash** defined
  in §5.1 (low 32 bits of `dispatch.hashValue(key)`). It is stored so
  lookup can reject a mismatched query hash in O(1) before any per-entry
  `=` walk. Not an independent hash; not pre-domain-mix.
- Entries are stored in **association order** as a representation
  detail (like array-map). Equality/hash at this layer is semantic
  (per §2.3) — no canonical ordering over arbitrary keys.

---

### 5. Indexing hash, shift schedule, promotion, dissoc

#### 5.1 Indexing hash

Keys are indexed by the **low 32 bits** of the key's `dispatch.hashValue(key)`
result. The hash is computed once per lookup/update and reused
throughout. Since `dispatch.hashValue` already applies the
equality-category domain mixer, this is the same hash value that
would be written to `HeapHeader.hash` for heap-kind keys; no second
xxHash3 invocation per key per op.

```zig
inline fn indexHashOf(key: Value, elementHash: *const fn (Value) u64) u32 {
    if (!key.kind().isHeap()) return @truncate(key.hashImmediate());
    return @truncate(elementHash(key));
}
```

(`elementHash` is `&dispatch.hashValue` at every real call site; the
module takes it as a parameter rather than importing `dispatch.zig`.
An immediate key hashes through `Value.hashImmediate` directly: that
is the value `dispatch.hashValue` computes for every non-heap kind,
so the index is the same either way and a keyword or fixnum key
skips the callback. `elementHash` is consulted for heap keys only.
A test fixture that shapes the indexing hash through the callback
therefore keys by heap values, strings in every collision fixture,
and asserts through `mapCollisionCount` / `setCollisionCount` that
its keys reached the collision node; an immediate key would never
see the fixture's hash and the trie would partition it cleanly.)

Rationale for low-32 (vs. high-32 / XOR-fold): freeze one rule;
pick the simpler. Truncation does not bias distribution because
xxHash3 output is uniform across 64 bits.

#### 5.2 Level shifts

- Levels 0..5 each consume 5 bits in 5-bit chunks (30 bits total).
- Level 6 consumes the remaining 2 bits (bitmap still `u32` but only
  slots 0..3 are reachable).
- After all 32 indexing bits are exhausted, two keys with equal 32-bit
  indexing hashes are placed in a collision node (§4.4).

| Level | Shift | Fragment width | Reachable slots |
|-------|-------|----------------|-----------------|
| 0 | 0 | 5 bits | 0..31 |
| 1 | 5 | 5 bits | 0..31 |
| 2 | 10 | 5 bits | 0..31 |
| 3 | 15 | 5 bits | 0..31 |
| 4 | 20 | 5 bits | 0..31 |
| 5 | 25 | 5 bits | 0..31 |
| 6 | 30 | 2 bits | 0..3 |

Slot index at a node with shift `s` is `(hash >> s) & 0x1F`.

Frozen constant:

```zig
pub const MAX_TRIE_SHIFT: u8 = 30;  // shift at the deepest interior level (levels 0..6)
```

Not configurable. 64-bit indexing would be a spec amendment.

#### 5.3 Array-map → CHAMP promotion

Trigger: `assoc` on a subkind-0 array-map at count 8, adding an entry
whose key is not already present. Result: a subkind-1 CHAMP root
with exactly 9 entries in a root interior at shift 0, with subtrees
below it wherever keys share a 5-bit slot. The nine are sorted by
their slot path and the trie is built bottom-up, one allocation per
node (the same builder serves `mapFromEntries` / `setFromElements`,
§8.1), so the result is the canonical trie of the nine keys.

Promotion is deterministic in the final tree shape for a given
key-set, but the representation the user observes changes subkind
mid-operation — which is why cross-subkind equality (§2.4) must
work.

#### 5.4 No demotion on dissoc

A CHAMP root that shrinks below 8 entries via `dissoc` does NOT
demote back to array-map. This matches Clojure's
`PersistentHashMap.without` behavior: demotion churn at the 8↔9
boundary would dominate real workloads that bounce around that
threshold.

Consequence: two logically-equal maps may have different subkinds
depending on their construction history. Equality and hash handle
this via §2.4's semantic fallback; no user-visible behavior changes.

#### 5.5 Single-entry-subtree promotion on dissoc

When `dissoc` empties all entries out of an interior subtree except
for a single entry at one depth, that entry is **pulled up** into
the parent's data area. If the parent's only content was that
subtree, the parent would itself hold the lone entry, so the entry
passes further up, level by level, until it reaches a node with other
content or the root. A collision node left with one entry starts the
same climb from the bottom of the trie. This preserves canonicality
of CHAMP node shape: an interior node with one entry and no children
cannot exist anywhere but at the root.

Skipping this promotion would be simpler but would break bitmap
canonicality — two equal maps built by different paths could
differ by a "lonely interior node" in one and a "direct data entry"
in the other. The bitmap early-exit equality fast path would then
produce false negatives.

#### 5.6 Dissoc at the root

When `dissoc` removes the last entry of a CHAMP root, the result is
a fresh empty array-map (subkind 0, count 0), NOT a subkind-1 root
with a null pointer. The subkind-1 invariant is `root_node != null`;
an empty CHAMP would violate that.

When `dissoc` leaves a CHAMP root with exactly one entry, the result
is the **same subkind-1 CHAMP root** holding one entry in a trivial
interior node at the root position. (It does NOT demote to array-map
per §5.4.)

---

### 6. Equality contract

#### 6.1 Category filter (already in dispatch.zig)

`dispatch.equal(a, b)` first checks `eqCategory(a.kind()) ==
eqCategory(b.kind())`. Map and set are in different categories
(associative vs set), so `(= {:a 1} #{:a 1})` is false without ever
consulting the map/set module. This is handled entirely upstream;
this doc inherits the guarantee.

#### 6.2 Within-category dispatch

For two Values in the `.associative` category, `dispatch.equal`
routes through:

```zig
fn associativeEqual(a: Value, b: Value) bool;
```

This reduces to same-kind dispatch (only `persistent_map` exists in
the category), but the shape is the seam for any cross-kind
associative member. Same shape for `setEqualCategory` in the set
category.

#### 6.3 Same-kind, same-subkind equality

| Subkind pair | Strategy |
|---|---|
| (0, 0) array-map ↔ array-map | O(n²) membership: count match, then every (k,v) in `a` is found in `b` |
| (1, 1) CHAMP ↔ CHAMP | Count match, then recursive node structural compare starting at roots; bitmap early-exit enabled |
| (3, 3) collision ↔ collision | Count match, shared-hash match, then O(k²) semantic membership |

Recursive node structural compare:
- Bitmaps equal? If not, return false.
- For each data slot: recursive `dispatch.equal` on key and on value.
- For each node slot: recursive structural compare on children. If
  the child pair is (interior, interior), recurse. If either is a
  collision node, fall through to semantic membership compare at
  that subtree.

#### 6.4 Same-kind, cross-subkind equality

Subkind pairs (0, 1) and (1, 0) — array-map vs. CHAMP root:

- Count match first.
- Then iterate the side with the cheaper iteration / smaller bound
  (always the array-map side, since it is capped at 8 entries).
  For each entry (k, v), call `mapGet(otherMap, k)`:
  - `.absent` → return false.
  - `.present = v'` → compare `v == v'` via `dispatch.equal`; unequal
    → return false.
- If the iteration completes, return true.

Subkind pair (3, anything-other-than-3) cannot occur as a
**top-level** comparison — subkind 3 is internal and never escapes
as a user-facing Value. Collision nodes only appear nested inside
CHAMP tree walks, where §6.3 handles them.

**Nil-value correctness.** Nil is a legal map value. The `?Value`
return shape would conflate "absent" with "present with nil value",
which would break this equality strategy on maps containing nil
values. The `MapLookup` union in §6.6 / §8 fixes this at the API
level; this §6.4 strategy depends on that fix.

#### 6.5 Keyword-keyed fast path

Per PLAN §9.1: when both the search key and the candidate key are
`.keyword`, compare via **interned-id identity**
instead of calling through `dispatch.equal`. Scope narrowly — this
shortcut applies only to same-kind keyword pairs. Every other key
kind pair routes through `dispatch.equal`.

Rationale: the keyword intern-id check is a single u32 compare; the
`dispatch.equal` path goes through kind-category dispatch and a
function-pointer indirection. For keyword-keyed maps (the dominant
idiom — `:user/name`, `:status`, `:id`), the fast path eliminates
the call-through in the inner loop.

Correctness: two Values with `kind == .keyword` and equal payload
ids are `=` by intern-table invariants. Two Values with
`kind == .keyword` and different payload ids are never `=`. So the
shortcut is equivalent to `dispatch.equal` for this kind pair, not
an approximation.

#### 6.6 `mapGet` returns `MapLookup`, not `?Value`

Two distinct points:

1. **Absence is normal programmatic flow**, not a contract violation
   (unlike `vector.nth` out-of-bounds). Map lookup must not panic
   on an absent key.
2. **`?Value` would conflate "absent" with "present with nil value"**
   because nil is a legal map value (nothing in SEMANTICS.md §2.6 or
   PLAN §9.1 prohibits it, and prohibiting it would break
   `(nil-propagation) (assoc m k nil)` idioms). The API must
   distinguish the two cases explicitly.

The API:

```zig
pub const MapLookup = union(enum) {
    absent,
    present: value.Value,
};

pub fn mapGet(m: value.Value, key: value.Value,
              elementHash: *const fn (Value) u64,
              elementEq: *const fn (Value, Value) bool) MapLookup;
pub fn setContains(s: value.Value, elem: value.Value,
                   elementHash: *const fn (Value) u64,
                   elementEq: *const fn (Value, Value) bool) bool;  // set: presence-only
```

The language-surface `(get m k)` returns `nil` on absent;
`(get m k default)` returns the default; `(contains? s e)` returns
a bool. Those wrappers switch on the union in the stdlib natives
(`src/stdlib.zig`).

---

### 7. Hash contract

#### 7.1 Entry-hash function (map)

For a map entry `(k, v)`:

```
entry_hash(k, v) =
    combineOrdered(
        combineOrdered(ordered_init, dispatch.hashValue(k)),
        dispatch.hashValue(v))
```

= `31 * (31 + hash(k)) + hash(v)` (with wrap-around u64 arithmetic).

This is **two `combineOrdered` calls, no `finalizeOrdered`, no
sequential-domain mix**. SEMANTICS.md §3.2 pins this formula. The
informal reading `h += hasheq(list(k, v))` is NOT the contract: it
would route entries through the full sequential hash pipeline (which
adds a `finalizeOrdered(..., 2)` + `mixKindDomain(..., 0xF0)` per
entry), which is both more expensive and semantically wrong (the
0xF0 sequential-domain byte has no business inside a map's internal
entry hash).

Rationale:
- Two ordered combines keep the hash sensitive to swapped key/value
  positions within a pair (stronger than Clojure's
  `hash(k) XOR hash(v)`, which is commutative in k, v).
- No inner finalize: the outer map-level `finalizeUnordered(..., count)`
  already disambiguates empty-vs-populated and count-differing maps.
- No inner domain mix: the outer `mixKindDomain(..., 0xF1)` applied
  by `dispatch.hashValue` at the map level is the correct and only
  domain fold.

#### 7.2 Aggregate hash (map)

```
hashMap(h, entryIter):
    var acc: u64 = hash.unordered_init;
    while (iter.next()) |entry| {
        acc = hash.combineUnordered(acc, entry_hash(entry.key, entry.value));
    }
    return hash.finalizeUnordered(acc, count);
```

The final `finalizeUnordered(acc, count)` folds in the entry count to
disambiguate empty vs. non-empty cases and isolate count-differing
maps into distinct hash regions.

#### 7.3 Aggregate hash (set)

Same shape, without the (k, v) inner combine:

```
hashSet(h, elementIter):
    var acc: u64 = hash.unordered_init;
    while (iter.next()) |elem| {
        acc = hash.combineUnordered(acc, dispatch.hashValue(elem));
    }
    return hash.finalizeUnordered(acc, count);
```

#### 7.4 Domain mixing

`dispatch.hashValue` applies `mixKindDomain(base,
domainByteForKind(k))` at the top level. For maps, this fold uses
`0xF1` (associative category); for sets, `0xF2` (set category).
Both domain bytes are already declared as constants in `dispatch.zig`.
Two maps with the same entries — regardless of whether they're
array-map, CHAMP, or a mix across the comparison — produce identical
final hashes because:
1. Every entry's hash comes from the same `dispatch.hashValue` path.
2. Every representation uses `combineUnordered` (order-independent).
3. The same category domain byte folds in at the end.

This is the bedrock `(= a b) ⇒ (hash a) = (hash b)` invariant in
action across subkinds.

#### 7.5 Hash caching

Per HEAP.md's cache-if-nonzero rule: a computed `u32` of zero is not
written to `HeapHeader.hash` (uncomputed sentinel). The cache is the
domain-mixed final hash value (actually the u32 truncation of it)
per the pattern established by string and bignum.

For map/set roots, the cached hash accelerates repeated `hash(m)`
calls. For internal interior and collision nodes, hash caching is
**not** beneficial — those nodes aren't user-addressable and their
hashes are recomputed as part of root-level `hashMap` traversal
anyway. Interior/collision node bodies therefore do not cache hash;
the root body caches via the standard `HeapHeader.hash` slot.

---

### 8. Public API

Lives in `src/coll/champ.zig`. Map and set operations are prefixed for
clarity because both live in the same module.

Every operation that must hash or compare keys takes the hash and
equality functions as explicit parameters (`elementHash` /
`elementEq`); callers pass `&dispatch.hashValue` / `&dispatch.equal`.
The module never imports `dispatch.zig` directly.

```zig
const ElementHash = *const fn (value.Value) u64;
const ElementEq = *const fn (value.Value, value.Value) bool;

// -- Map --
pub const Entry = extern struct { key: value.Value, value: value.Value };  // 32 bytes

pub const MapLookup = union(enum) {
    absent,
    present: value.Value,
};

pub fn mapEmpty(heap: *Heap) !value.Value;
pub fn mapFromEntries(heap: *Heap, entries: []const Entry, elementHash: ElementHash, elementEq: ElementEq) !value.Value;
pub fn mapAssoc(heap: *Heap, m: value.Value, key: value.Value, val: value.Value, elementHash: ElementHash, elementEq: ElementEq) !value.Value;
pub fn mapDissoc(heap: *Heap, m: value.Value, key: value.Value, elementHash: ElementHash, elementEq: ElementEq) !value.Value;
pub fn mapGet(m: value.Value, key: value.Value, elementHash: ElementHash, elementEq: ElementEq) MapLookup;
pub fn mapCount(m: value.Value) usize;

// -- Set --
pub fn setEmpty(heap: *Heap) !value.Value;
pub fn setFromElements(heap: *Heap, elems: []const value.Value, elementHash: ElementHash, elementEq: ElementEq) !value.Value;
pub fn setConj(heap: *Heap, s: value.Value, elem: value.Value, elementHash: ElementHash, elementEq: ElementEq) !value.Value;
pub fn setDisj(heap: *Heap, s: value.Value, elem: value.Value, elementHash: ElementHash, elementEq: ElementEq) !value.Value;
pub fn setContains(s: value.Value, elem: value.Value, elementHash: ElementHash, elementEq: ElementEq) bool;
pub fn setCount(s: value.Value) usize;

// -- Dispatch entry points (called by dispatch.zig) --
pub fn hashMap(h: *HeapHeader, elementHash: ElementHash) u64;
pub fn hashSet(h: *HeapHeader, elementHash: ElementHash) u64;
pub fn equalMap(a: *HeapHeader, b: *HeapHeader, elementHash: ElementHash, elementEq: ElementEq) bool;
pub fn equalSet(a: *HeapHeader, b: *HeapHeader, elementHash: ElementHash, elementEq: ElementEq) bool;

// -- Iterators for hash accumulation and seq --
pub const MapIter = ...;  // init(m), next() ?Entry
pub const SetIter = ...;  // init(s), next() ?Value
pub fn mapIter(m: value.Value) MapIter;
pub fn setIter(s: value.Value) SetIter;

// -- GC trace entry points (called by gc.zig) --
pub fn traceMap(h: *HeapHeader, visitor: anytype) void;
pub fn traceSet(h: *HeapHeader, visitor: anytype) void;

// -- Trie introspection for tests (§4.3, §12.3) --
pub fn mapCollisionCount(m: value.Value, hash32: u32) ?u32;
pub fn setCollisionCount(s: value.Value, hash32: u32) ?u32;
pub fn canonicalTrie(v: value.Value, elementHash: ElementHash) bool;
```

#### 8.1 Error set and semantic details

- All constructing / updating functions may return `error.OutOfMemory`
  from `heap.alloc`. No other error paths.
- `mapFromEntries` on an input with duplicate keys does NOT error —
  **later entry wins**. This is Clojure's
  runtime behavior for programmatically-built maps with duplicate
  keys, distinct from the reader's static duplicate-literal-key
  rejection. `setFromElements` same: duplicate elements are
  deduplicated. Both return exactly what a left fold of `mapAssoc` /
  `setConj` from empty returns (same subkind, same trie, same
  iteration order), built bottom-up instead: the payloads are sorted
  by their slot path, equal keys merged, and each node allocated once.
- `mapAssoc` on an existing key:
  - if the existing value is bit-identical to the new value (same
    tag and payload), return the same map pointer (identity
    preserved; no allocation). Avoids churn on idempotent updates; a
    value that is `=` but not identical is stored.
  - otherwise, replace the value, keeping the key object already
    stored (Clojure's behavior); count unchanged; path copied as
    needed.
- `mapAssoc` on an absent key:
  - array-map with count < 8: append the entry; count +1.
  - array-map with count == 8: promote to CHAMP root; count +1.
  - CHAMP: recurse down the trie path; count +1.
- `mapDissoc` on an absent key: return the same map pointer (no
  allocation). Clojure's behavior.
- `mapDissoc` on a present key: remove the entry; count -1; apply
  single-entry-subtree promotion (§5.5) and empty-subtree collapse
  (trap #4) as needed; if result count is 0, return a fresh subkind-0
  empty array-map.

#### 8.2 Nil-as-key / nil-as-value / nil-as-element (frozen)

- **Nil is a legal map key.** SEMANTICS.md §3.2 defines `hash(nil) =
  0xB01DFACE`; `dispatch.equal(nil, nil)` is true. The hash and
  equality functions return deterministic, consistent values for nil
  in both key and value positions; no special-case logic is needed in
  the map implementation.
- **Nil is a legal map value.** Required for the nil-propagation
  rule `(assoc m k nil)` to produce a map containing `(k, nil)`. The
  `MapLookup` union in §6.6 / §8 is what makes lookup's
  present-with-nil-value distinguishable from absent.
- **Nil is a legal set element.** `(conj #{} nil)` produces `#{nil}`;
  `(contains? #{nil} nil)` is true.

#### 8.3 Panic contracts

- `mapGet(m, k)` returns a `MapLookup`; never panics on absence (for
  well-formed maps). Panics via safe-assert only on a non-map Value
  or a malformed internal subkind.
- `mapCount(m)` — safe-asserts the Value is a map
  kind; panic otherwise (caller bug).
- `mapAssoc` / `mapDissoc` on a non-map Value panic. Language surface
  provides the nil-propagation layer (`(assoc nil k v) → {k v}`, in
  the `assoc` native in `src/stdlib.zig`).

---

### 9. Dispatch integration

`dispatch.zig` integrates the module at three points:

1. Two kind arms in `heapHashBase`:

```zig
.persistent_map => champ.hashMap(h, &hashValue),
.persistent_set => champ.hashSet(h, &hashValue),
```

2. Two category-equality helpers paralleling `sequentialEqual`:

```zig
fn associativeEqual(a: Value, b: Value) bool;
fn setEqualCategory(a: Value, b: Value) bool;
```

These reduce to same-kind dispatch because each category has one
kind. The `dispatch.equal` switch routes:

```zig
.associative => return associativeEqual(a, b),
.set => return setEqualCategory(a, b),
```

(`heapEqual` also carries `.persistent_map` / `.persistent_set` arms
calling `champ.equalMap` / `champ.equalSet` for the same-kind path.)

3. `eqCategory`, `domainByteForKind`, the category domain-byte
constants, and the exhaustive `eqCategory + domainByteForKind` table
test all include map and set rows.

---

### 10. Implementation traps

Checklist of classic mistakes — tests must cover each.

1. **Bitmap popcount arithmetic.** Data position for slot `i` is
   `popCount(data_bitmap & ((1 << i) - 1))`. Off-by-one here produces
   silent wrong lookups for every slot but the first.
2. **Data and node bitmaps disjoint invariant.** `data_bitmap &
   node_bitmap == 0`. Violating it means a slot is interpreted two
   ways; assoc may silently drop or duplicate entries.
3. **Single-entry-subtree promotion on dissoc.** Skipping this breaks
   CHAMP canonicality as covered in §5.5.
4. **Empty-subtree collapse on dissoc.** A subtree whose last entry
   was dissoc'd must be removed from the parent (clear the node-bitmap
   bit) rather than left as a dangling empty interior node.
5. **Array-map duplicate-key overwrite.** `assoc` on an existing key
   replaces the value in place; count unchanged.
6. **Array-map same-value short-circuit.** `assoc` where the existing
   value is already `=` to the new value returns the same map pointer
   without allocating.
7. **Promotion boundary.** `assoc` on count=8 array-map adding a
   new key produces a CHAMP root, not a 9-entry array-map.
8. **Promotion preserves multiset equality.** The 9 entries of the
   promoted CHAMP must be the same entries (by `=`) as the pre-promotion
   array-map plus the new (k, v), in any order.
9. **Collision-node creation path.** When two keys with identical
   32-bit hashes still share a slot at `shift == MAX_TRIE_SHIFT`,
   create a collision node holding both. Do NOT attempt to split the hashes
   further — there are no more bits.
10. **Collision-node lookup short-circuit on shared_hash.** Compare
    the search key's hash against `shared_hash` first; if unequal,
    the key cannot be in this collision bucket regardless of `=`.
11. **`mapGet` on absent key in CHAMP.** Must walk slot-index path;
    must NOT return `null` early just because a slot is empty — the
    key might be in a collision node nested deeper.
12. **`_pad` bytes never hashed / compared.** The same discipline as
    `bignum.zig` applies to array-map and CHAMP root.
13. **Hash cache discipline.** Cache only nonzero u32 results at the
    root; never cache on interior/collision subkind bodies.

---

### 11. One trie for both kinds

`src/coll/champ.zig` implements the trie once, as `Trie(P, kind)`
generic over the payload `P`: `Entry` (32 bytes, key and value) for
`persistent_map`, a bare key `Value` (16 bytes) for `persistent_set`.
The payload type decides three things: how a payload's key is read,
whether storing a payload over an equal key changes anything (a
set's never does; a map's does unless the value is bit-identical),
and how a payload hashes (§7.1 entry hash vs. the element hash).
Every layout, bitmap rule, promotion, dissoc rule, iterator and
trace is shared. The public `map*` / `set*` functions, `MapIter` /
`SetIter`, `hashMap` / `hashSet`, `equalMap` / `equalSet` and
`traceMap` / `traceSet` are thin wrappers over the two instances.

Every path copy goes through one primitive: a copy of an interior
node with one slot changed to empty, an inline payload, or a child.
Lookup is an iterative descent; insert and remove recurse to at most
eight levels.

All three equality categories (`.sequential`, `.associative`,
`.set`) have concrete runtime members and property-test coverage of
the `(= a b) ⇒ (hash a) = (hash b)` invariant (§12).

---

### 12. Testing strategy

#### 12.1 The cross-category invariant tests

The parallel of `test/prop/vector.zig` V3 for associative and set:

**Build-order independence (M11; inline `hashMap` / `hashSet`
insertion-order tests).** Random entry sequences built in different
`assoc` orders must compare `=` and hash equal. Sizes vary across the
array-map → CHAMP boundary.

**Cross-subkind (M6, S5).** Force one map to stay subkind 0
(count ≤ 8), force another of the same entries to be subkind 1 via
promote-then-dissoc. Assert `=` and hash equal. Same for sets.

#### 12.2 Same-category, different-kind

`.associative` has one member. If another kind joins (a sorted map),
the equivalent of `test/prop/vector.zig` V3's list↔vector cross-kind
test slots in via the `associativeEqual` helper.

#### 12.3 Structural cliff edges

The counts at which representation changes, and which boundary
tests target:

- count 0, 1, 7, 8 (array-map only)
- count 9 (first promotion; single interior node)
- count 32, 33 (bitmap boundary within a node)
- count 1024 (level-2 first promotion; trie depth 2)
- Hash-collision stress: string keys all hashing to the same 32-bit
  value (a hash-colliding test fixture: low 32 bits pinned to
  `0xDEAD_BEEF`; heap keys because the callback is consulted for
  heap keys only, §5.1) forcing collision nodes. `mapCollisionCount`
  / `setCollisionCount` descend the trie along a 32-bit hash and
  report the entry count of the collision node at the bottom, or
  `null` when the descent leaves the trie earlier; every collision
  test asserts the count so the fixture cannot degrade into a
  cleanly partitioned trie without failing.

#### 12.4 Property tests (`test/prop/champ.zig`)

Map:

- M1. `mapFromEntries` + `mapGet` round-trip: every inserted (k, v)
  looks up to exactly `v`; absent keys return `.absent`.
- M2. `mapAssoc` + `mapDissoc` random sequences on random starting
  maps preserve the entry multiset minus dissoc'd keys.
- M2b. At 2000 and 30000 keys, `assoc` and `dissoc` keep the
  canonical layout (`canonicalTrie`, §4.3), and equal maps built in
  different orders iterate in the same order. S2b is the set side.
- M3. `mapAssoc` replace-value: associng `(k, v1)` then `(k, v2)`
  yields `mapGet(m, k) == v2` with unchanged count.
- M4. `assoc` same-value short-circuit returns the same map pointer.
- M5. Equality laws over random maps: reflexive, symmetric, transitive.
- M6. Cross-subkind hash equivalence (A2's setup across 500 random
  maps).
- M7. Cross-category never-equal: a map is never `=` to any
  non-associative Value; hashes distinct.
- M8. Persistent immutability: `mapAssoc(m1, k, v)` does not mutate
  `m1`; `mapGet(m1, k)` returns its original value.
- M9. Keyword-keyed fast path correctness: maps keyed entirely by
  keywords give the same results as maps keyed by other kinds — the
  fast path is an optimization, not a semantic change.
- M10. Collision-bucket stress: synthetic collision fixture builds
  a map with 5+ collision-bucket entries, asserts `mapGet` finds
  each, `mapDissoc` removes each, `=` and hash invariants hold.
- M11. `=` ⇒ `hashValue`-equal over random map pairs built in two
  insertion orders.

Set: S1–S9, parallel over set operations (S5 is the cross-subkind
array-set vs. CHAMP receipt).

---

### 13. Outside this module, explicitly

Listed so nothing silently slips the scope boundary.

- **Transients.** `src/coll/transient.zig`, spec `docs/TRANSIENT.md`.
- **`merge` / `merge-with` / `update` / `select-keys` / `reduce-kv` /
  `group-by` / etc.** Stdlib material composing over `assoc` /
  `dissoc` / `get` (`src/stdlib.zig` natives and
  `src/stdlib/core.nx`).
- **Set operators** (`union` / `intersection` / `difference`). Not
  implemented anywhere.
- **SIMD-accelerated bitmap operations** (T2.1 per PLAN §19.6). Not
  implemented; `champ.zig` uses scalar popcount.
- **Branchless small-bitmap lookup** (T2.8). Not implemented.
- **Zero-copy map nodes from emdb pages** (T2.2). Not implemented.
- **Cross-kind associative members** (sorted-map or similar). None
  exist; adding one requires a spec amendment.

---

### 14. What CHAMP.md does not cover

- **`champ.zig` implementation details** — popcount rank helpers,
  the slot-edit and bottom-up build helpers, layout access functions.
  Those are module-internal and documented via inline comments, not
  here.
- **Serialization wire format** — lives in `docs/CODEC.md`. Map and
  set are on the frozen-serializable list (PLAN §23 #25).
- **Language-surface `seq` API** — PLAN §6.7. The `MapIter` /
  `SetIter` types in §8 are the runtime-internal iteration seam;
  user-facing `(seq m)` / `(keys m)` / `(vals m)` are stdlib natives
  in `src/stdlib.zig` built on them.
- **Print/read round-trip** — the reader parses `{:a 1}` and
  `#{1 2}` into Form trees; the Value→textual direction lives in
  `src/format.zig` (`formatMap` / `formatSet`).
- **Metadata** — maps and sets are metadata-attachable per
  SEMANTICS.md §7. The `HeapHeader.meta` slot is the storage; no
  special map/set logic. Metadata never affects equality or hash
  (PLAN §23 #12).
