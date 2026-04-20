## CHAMP.md — Persistent Map & Set Heap Kinds (Phase 1)

**Status**: Phase 1 deliverable. Authoritative body-layout and semantic
contract for the `persistent_map` and `persistent_set` heap kinds.
Derivative from `PLAN.md` §9.1 + §23 #37, `docs/VALUE.md` §2.2,
`docs/SEMANTICS.md` §2.6 / §3.2, `docs/HEAP.md`, and the precedents
set by `docs/LIST.md` and `docs/VECTOR.md`. Those documents win on
conflict. Reviewed against `CLOJURE-REVIEW.md` §2.2 and peer-AI turn 8.

**Filename note.** The module ships as `src/coll/hamt.zig` for
historical consistency with `PLAN.md` §22's pre-decision repository
layout. The **algorithm is CHAMP** (Steindorfer & Vinju, OOPSLA 2015
— separate data and node bitmaps, canonical layout), not classic
Bagwell HAMT. Same pattern as `src/coll/rrb.zig` housing a plain
32-way persistent vector (NOT RRB-relaxed) per PLAN §23 #30 / VECTOR.md.
Classic HAMT is documented as a fallback (§1 "Out") only if CHAMP
implementation hits an unforeseen blocker — it did not.

This module ships the **associative** and **set** equality categories
(hash-domain bytes `0xF1` and `0xF2`). These are the only two equality
categories whose machinery is pre-wired in `dispatch.zig` but whose
runtime members are, prior to this commit, design fiction — the
category/domain scaffolding and exhaustive table tests already pin
`.persistent_map` and `.persistent_set` to their categories; this
commit gives them bodies.

This is the single largest implementation item remaining in Phase 1
per PLAN §25's risk register. Scope-frozen commitment: **this doc
specifies both kinds; implementation splits across two commits —
map core + associative infrastructure first, then set as a parallel
subkind family reusing the shared CHAMP machinery.**

---

### 1. Scope

**In (combined across both commits):**

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
- Three composition helpers in `dispatch.zig`: `associativeEqual`
  and `setEqual` parallel to the existing `sequentialEqual`. (These
  handle within-category equality; since each category currently has
  one kind, they reduce to kind-local dispatch today, but the shape
  is correct for future cross-kind associative / set extensions.)

**Out (each deferred to a named later commit or v2+):**

- **Transients**. Owner-token editable copies land with
  `src/coll/transient.zig`. This commit designs node layouts for
  persistent semantics only; if transients require layout revision
  when they land, that revision is an explicit transient-commit
  concern. Per peer-AI turn 8: no speculative reservation of transient
  fields in CHAMP nodes today.
- `merge` / `merge-with` / `update` / `select-keys` / `zipmap` and
  other stdlib-level map operators. Those compose over `assoc` /
  `dissoc` / `get` and are Phase 3 material.
- Set operators (`union` / `intersection` / `difference`). Same
  status as the stdlib map operators.
- RRB-style balancing for maps. Not a thing — CHAMP is already the
  committed layout. Listed here only to pre-empt the question.
- Cross-kind associative or set members. v1 has one kind per
  category; future kinds in the same category (e.g. sorted-map) are
  v2+ territory and require an amendment.

---

### 2. The three-layer canonicality model (central)

**Peer-AI turn 8 flagged overclaiming canonical representation as
the single most likely spec mistake here.** The rule set below is
deliberately narrower than a naive "CHAMP guarantees a unique layout
for any logical entry set" reading of PLAN §9.1.

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
  and potentially language-level ordering primitives. v1 does not
  accept that commitment.
- Collision-node equality is **semantic membership comparison**:
  same count, then every entry in `a` has an equal-keyed entry in
  `b`. O(k²) in the collision-bucket size k, which is tiny.
- Bitmap early-exit does NOT apply to collision-node payloads beyond
  trivial checks (same count, same shared 32-bit hash).

#### 2.4 Cross-subkind equality

- Two maps with the same entry set but different subkinds (e.g. an
  array-map built to 8 entries vs. a CHAMP-backed map that was once
  9 entries and then had one `dissoc`-ed out) compare `=` and hash
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
representation families within each kind; peer-AI turn 8 recommended
**parallel subkind numbering across both kinds** to keep dispatch and
future GC logic regular.

| Subkind | Map role | Set role | User-facing? |
|---------|---------|---------|---|
| 0 | array-map (inline ≤ 8 entries) | array-set (inline ≤ 8 elements) | yes |
| 1 | CHAMP root (count + pointer to root node) | CHAMP root (count + pointer to root node) | yes |
| 2 | CHAMP interior node | CHAMP interior node | no (internal) |
| 3 | collision node | collision node | no (internal) |
| 4..15 | reserved | reserved | — |

Only subkinds 0 and 1 ever flow through `dispatch.heapHashBase` /
`dispatch.heapEqual`. Subkinds 2 and 3 are internal allocations —
the heap holds them, GC will trace them, but they never escape into
a user-visible `Value`. Each accessor safe-asserts the subkind of
the header it receives.

**Empty collections.** A fresh empty map is `subkind = 0, count = 0`
(a zero-entry array-map). Same for sets. Per the list / vector
precedent, empty collections are **not** a shared singleton — each
`empty(heap)` call allocates a fresh header. Shared-singleton
pinning is a Phase 6 allocator optimization, tracked but not
scheduled.

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
- `_pad` bytes are never fed into hash or equality. (Peer-AI caught
  the same trap in `bignum.zig`: layout detail leaking into hash
  output.)
- Empty array-map / array-set: body size = 8 bytes; no trailing
  entries.

#### 4.2 CHAMP root body (subkind 1)

```zig
const ChampRootBody = extern struct {
    count: u32,                  // total entries across the whole trie
    _pad: u32,
    root_node: *HeapHeader,      // points to a subkind-2 (interior) or
                                 // subkind-3 (collision) node
};  // 16 bytes
```

- Always has a non-null `root_node` — an empty collection lives in
  subkind 0 (array-map/set with count 0), never in subkind 1.
- `count` is the authoritative total; it makes `count(v)` O(1) for
  user code and means interior nodes do NOT need to cache subtree
  counts. `assoc` / `dissoc` maintain a `changed: bool` flag passed
  through the recursion and adjust root count at the outer layer.
  (Clojure's pattern; simpler than per-node count caching.)
- `_pad` same semantic rules as above.

#### 4.3 CHAMP interior node (subkind 2)

```zig
const ChampInteriorBody = extern struct {
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
  {inline-entry, child-pointer}, never both. Safe-build code asserts
  this on every traversal.
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
  somewhere, and wrapping it in a one-entry interior at shift 0
  (built via `champSingleEntryInterior`) is the canonical form
  (§5.6).
  
  This invariant is what makes bitmap-level early-exit equality work
  **below the root_node level**: two equal CHAMP-backed maps at count
  ≥ 2 necessarily produce bit-identical bitmap chains at every
  corresponding interior node. At the root_node level, equal CHAMP
  maps of count 1 produce bit-identical single-entry interiors by the
  same token (both built via `champSingleEntryInterior` with
  matching entry and shift-0 slot index).
- **Entry types.** For `persistent_map`, each inline entry occupies
  32 bytes (`{ key: Value, value: Value }`). For `persistent_set`,
  each inline entry occupies 16 bytes (`key: Value`). The code module
  selects entry width by kind; bitmap semantics are identical.

The exact popcount expressions used at call sites live in
`src/coll/hamt.zig` and are covered by inline unit tests.

#### 4.4 Collision node (subkind 3)

```zig
const CollisionBody = extern struct {
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
result. Peer-AI turn 8: compute the hash once per lookup/update, reuse
it throughout. Since `dispatch.hashValue` already applies the
equality-category domain mixer, this is the same hash value that
would be written to `HeapHeader.hash` for heap-kind keys; no second
xxHash3 invocation per key per op.

```zig
fn indexHash(key: Value) u32 {
    return @truncate(dispatch.hashValue(key));
}
```

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

Frozen constants:

```zig
pub const MAX_TRIE_SHIFT: u5 = 30;  // shift at the deepest interior level
pub const COLLISION_DEPTH: u8 = 7;  // total levels (0..6) before collision
```

Not configurable in v1. Future 64-bit indexing would be a spec
amendment anyway.

#### 5.3 Array-map → CHAMP promotion

Trigger: `assoc` on a subkind-0 array-map at count 8, adding an entry
whose key is not already present. Result: a subkind-1 CHAMP root
with exactly 9 entries distributed into a single subkind-2 interior
node at shift 0. The interior node may in turn split further if the
existing-8 keys all land at the same 5-bit slot, but that's a rare
adversarial case (probability ~1-in-2³⁵ per random key) and the
generic assoc algorithm handles it via recursive promotion.

Promotion is deterministic in the final tree shape for a given
key-set, but the representation the user observes changes subkind
mid-operation — which is why cross-subkind equality (§2.4) must
work.

#### 5.4 No demotion on dissoc

A CHAMP root that shrinks below 8 entries via `dissoc` does NOT
demote back to array-map. Peer-AI turn 8 confirmed this matches
Clojure's `PersistentHashMap.without` behavior and is the right call:
demotion churn at the 8↔9 boundary would dominate real workloads that
bounce around that threshold.

Consequence: two logically-equal maps may have different subkinds
depending on their construction history. Equality and hash handle
this via §2.4's semantic fallback; no user-visible behavior changes.

#### 5.5 Single-entry-subtree promotion on dissoc

When `dissoc` empties all entries out of an interior subtree except
for a single entry at one depth, that entry is **pulled up** into
the parent's data area. This preserves canonicality of CHAMP node
shape: an interior node with one entry and no children cannot exist
anywhere but at the root.

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
routes through a new helper:

```zig
pub fn associativeEqual(a: Value, b: Value) bool;
```

Today this reduces to same-kind dispatch (only `persistent_map`
exists in the category), but the shape is correct for future
cross-kind associative members. Same shape for `setEqual` in the
set category.

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
  (for v1, always the array-map side since it's capped at 8 entries).
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

Per PLAN §9.1 and peer-AI turn 8: when both the search key and the
candidate key are `.keyword`, compare via **interned-id identity**
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

Peer-AI turn 8 / turn 9 flagged two distinct points here:

1. **Absence is normal programmatic flow**, not a contract violation
   (unlike `vector.nth` out-of-bounds). Map lookup must not panic
   on an absent key.
2. **`?Value` would conflate "absent" with "present with nil value"**
   because nil is a legal map value (nothing in SEMANTICS.md §2.6 or
   PLAN §9.1 prohibits it, and prohibiting it would break
   `(nil-propagation) (assoc m k nil)` idioms). The API must
   distinguish the two cases explicitly.

The v1 API:

```zig
pub const MapLookup = union(enum) {
    absent,
    present: value.Value,
};

pub fn mapGet(m: value.Value, key: value.Value) MapLookup;
pub fn setContains(s: value.Value, elem: value.Value) bool;  // set: presence-only
```

The language-surface `(get m k)` returns `nil` on absent;
`(get m k default)` returns the default; `(contains? s e)` returns
a bool. Those wrappers switch on the union at the macro / stdlib
layer.

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
sequential-domain mix**. SEMANTICS.md §3.2 was amended (2026-04-19,
in the same commit as this doc) to pin this formula; the previous
informal prose `h += hasheq(list(k, v))` was ambiguous — a strict
reading would route entries through the full sequential hash
pipeline (which adds a `finalizeOrdered(..., 2)` + `mixKindDomain(..., 0xF0)`
per entry), which is both more expensive and semantically wrong
(the 0xF0 sequential-domain byte has no business inside a map's
internal entry hash).

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

Lives in `src/coll/hamt.zig`. Map and set operations are prefixed for
clarity because both live in the same module.

```zig
// -- Map --
pub const Entry = struct { key: value.Value, value: value.Value };

pub const MapLookup = union(enum) {
    absent,
    present: value.Value,
};

pub fn mapEmpty(heap: *Heap) !value.Value;
pub fn mapFromEntries(heap: *Heap, entries: []const Entry) !value.Value;
pub fn mapAssoc(heap: *Heap, m: value.Value, key: value.Value, val: value.Value) !value.Value;
pub fn mapDissoc(heap: *Heap, m: value.Value, key: value.Value) !value.Value;
pub fn mapGet(m: value.Value, key: value.Value) MapLookup;
pub fn mapCount(m: value.Value) usize;
pub fn mapIsEmpty(m: value.Value) bool;

// -- Set --
pub fn setEmpty(heap: *Heap) !value.Value;
pub fn setFromElements(heap: *Heap, elems: []const value.Value) !value.Value;
pub fn setConj(heap: *Heap, s: value.Value, elem: value.Value) !value.Value;
pub fn setDisj(heap: *Heap, s: value.Value, elem: value.Value) !value.Value;
pub fn setContains(s: value.Value, elem: value.Value) bool;
pub fn setCount(s: value.Value) usize;
pub fn setIsEmpty(s: value.Value) bool;

// -- Dispatch entry points (called by dispatch.zig) --
pub fn hashMap(h: *HeapHeader, elementHash: *const fn (value.Value) u64) u64;
pub fn hashSet(h: *HeapHeader, elementHash: *const fn (value.Value) u64) u64;
pub fn equalMap(a: *HeapHeader, b: *HeapHeader, elementEq: *const fn (value.Value, value.Value) bool) bool;
pub fn equalSet(a: *HeapHeader, b: *HeapHeader, elementEq: *const fn (value.Value, value.Value) bool) bool;

// -- Iterators for hash accumulation and future seq --
pub const MapIter = struct { ... };
pub const SetIter = struct { ... };
pub fn mapIter(h: *HeapHeader) MapIter;
pub fn setIter(h: *HeapHeader) SetIter;
```

#### 8.1 Error set and semantic details

- All constructing / updating functions may return `error.OutOfMemory`
  from `heap.alloc`. No other error paths.
- `mapFromEntries` on an input with duplicate keys does NOT error —
  **later entry wins** (per peer-AI turn 8). This is Clojure's
  runtime behavior for programmatically-built maps with duplicate
  keys, distinct from the reader's static duplicate-literal-key
  rejection. `setFromElements` same: duplicate elements are
  deduplicated.
- `mapAssoc` on an existing key:
  - if the existing value is `=` to the new value, return the same
    map pointer (identity preserved; no allocation). Clojure's
    behavior; avoids churn on idempotent updates.
  - otherwise, replace the value; count unchanged; path copied as
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
- `mapCount(m)`, `mapIsEmpty(m)` — safe-assert the Value is a map
  kind; panic otherwise (caller bug).
- `mapAssoc` / `mapDissoc` on a non-map Value panic. Language surface
  provides the nil-propagation layer (`(assoc nil k v) → {k v}`, a
  macro in stdlib/core.nx).

---

### 9. Dispatch integration

`dispatch.zig` gains:

1. Two kind arms in `heapHashBase`:

```zig
.persistent_map => hamt.hashMap(h, &hashValue),
.persistent_set => hamt.hashSet(h, &hashValue),
```

2. Two new category-equality helpers paralleling `sequentialEqual`:

```zig
fn associativeEqual(a: Value, b: Value) bool;
fn setEqual(a: Value, b: Value) bool;
```

Today these reduce to same-kind dispatch because each category has
one kind. The `dispatch.equal` switch grows:

```zig
.associative => return associativeEqual(a, b),
.set => return setEqual(a, b),
```

(Replacing the current `.associative, .set, .kind_local => {...}`
fused arm which reduces to kind-local today.)

3. Nothing else changes. `eqCategory`, `domainByteForKind`, the
category domain-byte constants, and the exhaustive
`eqCategory + domainByteForKind` table test all already include
map and set rows; they light up on this commit without source
edits.

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
   32-bit hashes collide at `shift >= MAX_TRIE_SHIFT`, create a
   subkind-3 node holding both. Do NOT attempt to split the hashes
   further — there are no more bits.
10. **Collision-node lookup short-circuit on shared_hash.** Compare
    the search key's hash against `shared_hash` first; if unequal,
    the key cannot be in this collision bucket regardless of `=`.
11. **`mapGet` on absent key in CHAMP.** Must walk slot-index path;
    must NOT return `null` early just because a slot is empty — the
    key might be in a collision node nested deeper.
12. **`_pad` bytes never hashed / compared.** Already covered in
    bignum.zig's turn-6 peer-AI review; same discipline applies to
    array-map and CHAMP root.
13. **Hash cache discipline.** Cache only nonzero u32 results at the
    root; never cache on interior/collision subkind bodies.

---

### 11. Two-commit split (both landed)

Per peer-AI turn 8 and user confirmation:

**Commit 1 — map core + associative infrastructure.** [LANDED at `b20c306`]

- `docs/CHAMP.md` (this file).
- `src/coll/hamt.zig` with:
  - `.persistent_map` subkinds 0–3 fully implemented.
  - Map public API (`mapEmpty`, `mapFromEntries`, `mapAssoc`,
    `mapDissoc`, `mapGet`, `mapCount`, `mapIsEmpty`).
  - `hashMap`, `equalMap`, `MapIter`, dispatch integration.
- `test/prop/hamt.zig` with map property tests M1–M11.
- Inline map tests in `hamt.zig` (29 tests).
- `dispatch.zig` updates:
  - `heapHashBase` map arm.
  - `associativeEqual` helper.
  - `equal` switch update (split `.associative` out of fused arm).
- Green: 247 → 294 tests (+47).

**Commit 2 — set parallel implementation.** [LANDED this commit]

- `src/coll/hamt.zig` extended with the full set kind (parallel
  PART 2 section):
  - `.persistent_set` subkinds 0–3. Bodies share header layout
    structs with the map side (`ChampSetRootBody`, `SetInteriorHeader`,
    `SetCollisionHeader` are type aliases); entry storage differs
    (16-byte `Value` per element vs. 32-byte `Entry` per map
    key-value pair).
  - Set public API (`setEmpty`, `setFromElements`, `setConj`,
    `setDisj`, `setContains`, `setCount`, `setIsEmpty`).
  - `hashSet`, `equalSet`, `SetIter`, dispatch integration.
  - Parallel clone helpers: `cloneSetInteriorReplaceChild`,
    `cloneSetInteriorInsertElement`,
    `cloneSetInteriorMigrateDataToChild`,
    `cloneSetInteriorRemoveElement`,
    `cloneSetInteriorMigrateChildToData`.
  - Parallel recursive ops: `champSetConjInNode`,
    `champSetDisjFromNode`, `champSetContains`, collision node
    versions of each.
- `test/prop/hamt.zig` extended with set properties S1–S9
  (retirement receipt is S5 — cross-subkind array-set vs. CHAMP).
- Inline set tests (13 tests parallel to the map ones).
- `dispatch.zig` updates:
  - `heapHashBase` set arm (`hamt.hashSet`).
  - `heapEqual` set arm (`hamt.equalSet`).
  - `setEqualCategory` helper paralleling `associativeEqual` /
    `sequentialEqual`.
  - `equal` switch: fused `.set, .kind_local` arm split — `.set`
    now has its own arm.
- Green: 294 → 323 tests (+29). 10 goldens unchanged = 333 gates total.

Each commit shipped with spec coverage, peer-AI review, and property-
test receipts. Commit 1 retired the associative equality category's
hidden fault line; commit 2 retires the set category's. All three
equality categories (`.sequential`, `.associative`, `.set`) now have
concrete runtime members and property-test retirement receipts.

---

### 12. Testing strategy

#### 12.1 The cross-category invariant tests (retirement receipts)

The parallel of `test/prop/vector.zig` V3 for associative and set:

**A1 (commit 1).** 500 random entry sequences. For each sequence,
build a map by random `assoc` order and another by reverse order;
assert `=` and `hashValue`-equal. Varies sizes across the array-map
→ CHAMP boundary and well beyond.

**S1 (commit 2).** Same shape for sets. Random element sequences,
two build orders, `=` and hash equal.

**A2 (commit 1).** Cross-subkind: force one map to stay subkind 0
(count ≤ 8), force another of the same entries to be subkind 1 via
promote-then-dissoc. Assert `=` and hash equal.

**S2 (commit 2).** Same for sets.

#### 12.2 Same-category, different-kind (v1-future)

Today `.associative` has one member. If a future kind joins (sorted
map in v2+), the equivalent of `test/prop/vector.zig` V3's list↔vector
cross-kind test slots in naturally via the `associativeEqual`
cursor-like helper.

#### 12.3 Boundary tests

At structural cliff edges:

- count 0, 1, 7, 8 (array-map only)
- count 9 (first promotion; single interior node)
- count 32, 33 (bitmap boundary within a node)
- count 1024 (level-2 first promotion; trie depth 2)
- count 100,000 (realistic deep trie)
- Hash-collision stress: 10 keys all hashing to the same 32-bit
  value (use a custom hash-colliding test fixture) forcing collision
  nodes.

#### 12.4 Property tests (`test/prop/hamt.zig`)

Commit 1 (map):

- M1. `mapFromEntries` + `mapGet` round-trip: every inserted (k, v)
  looks up to exactly `v`; absent keys return null.
- M2. `mapAssoc` + `mapDissoc` random sequences on random starting
  maps preserve the entry multiset minus dissoc'd keys.
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

Commit 2 (set): parallel S1–S9 over set operations.

---

### 13. Deferred, explicitly

Listed so nothing silently slips the scope boundary.

- **Transients.** Phase 1 separate commit (`src/coll/transient.zig`).
- **`merge` / `merge-with` / `update` / `select-keys` / `reduce-kv` /
  `group-by` / etc.** Phase 3 stdlib material; compose over `assoc` /
  `dissoc` / `get`.
- **Set operators** (`union` / `intersection` / `difference`). Same.
- **SIMD-accelerated bitmap operations** (T2.1 per PLAN §19.6). Phase 6.
- **Branchless small-bitmap lookup** (T2.8). Phase 6.
- **Zero-copy map nodes from emdb pages.** Phase 6 T2.2.
- **Cross-kind associative members** (sorted-map or similar). v2+
  with amendment.

---

### 14. What CHAMP.md does not cover

- **`hamt.zig` implementation details** — lookup table for popcount,
  recursive node construction helpers, layout access functions. Those
  are module-internal and will be documented via inline comments, not
  here.
- **Serialization wire format** — lives in `docs/CODEC.md` (Phase 4).
  Map and set are on the frozen-serializable list (PLAN §23 #25).
- **Language-surface `seq` API** — PLAN §6.7 / Phase 3. The
  `MapIter` / `SetIter` types in §8 are the runtime-internal
  iteration seam; user-facing `(seq m)` / `(keys m)` / `(vals m)`
  come later.
- **Print/read round-trip** — the reader already parses `{:a 1}` and
  `#{1 2}` into Form trees; the Value→textual direction reuses the
  pretty-printer when the full Value-print story lands.
- **Metadata** — maps and sets are metadata-attachable per
  SEMANTICS.md §7. The `HeapHeader.meta` slot is the storage; no
  special map/set logic. Metadata never affects equality or hash
  (PLAN §23 #12).
