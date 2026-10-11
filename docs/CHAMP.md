## CHAMP.md — Persistent Map and Set Heap Kinds

The contract for the `persistent_map` and `persistent_set` heap kinds
(`src/coll/champ.zig`): a CHAMP trie (Steindorfer and Vinju, OOPSLA
2015: separate data and node bitmaps, a canonical layout) behind a flat
array form for up to 8 keys (PLAN §23 #37). Kind numbers:
`docs/VALUE.md` §2.2. Header bits: `docs/HEAP.md`. Equality category
and hash domain: `docs/SEMANTICS.md` §3.3. GC trace: `docs/GC.md` §5.
Serializable: `docs/CODEC.md` §3.

---

### 1. Scope

The module implements the trie once, for both kinds (§11), and
provides construction, `assoc`/`conj`, `dissoc`/`disj`, lookup,
`count`, an iterator, and the per-kind hash, equality and trace entry
points (§8). Costs:

| Operation | Cost |
|---|---|
| lookup (`mapGet`, `setContains`) | O(log₃₂ n): an iterative descent of at most 7 interior levels and a collision node |
| `assoc`/`conj`, `dissoc`/`disj` | O(log₃₂ n) path copy, one new node per level; an array form copies its ≤ 8 payloads |
| `mapFromEntries`, `setFromElements` | O(n log n): a sort by slot path, then one allocation per node |
| `count` | O(1) |
| `=` | O(n) lookups (§6.1) |
| `hash` | O(n) the first time; cached in the root header (§7.3) |

The language surface lives in `src/stdlib.zig`: `hash-map`, `hash-set`,
`set`, `assoc`, `dissoc`, `disj`, `get` (nil or the default when
absent), `contains?`, `find`, `keys`, `vals`, `key`, `val`, `zipmap`,
`select-keys`, `conj`, `into`, `frequencies`, `group-by`, `count`,
`empty`, and invocation (`({:a 1} :a)`, `(#{:x} :x)`, `(:a m)`).
`merge`, `merge-with`, `update`, `get-in`, `assoc-in`, `update-in`,
`update-vals` and `update-keys` are `src/stdlib/core.nx`; set algebra
is the `nexis.set` namespace (`src/stdlib/set.nx`). `(assoc nil k v)`
is `{k v}` (SEMANTICS §4). An update that changes nothing returns its
argument; any other update returns a new root carrying the argument's
metadata (SEMANTICS §7).

**Absent.** Sorted maps and sets are `src/coll/sorted.zig`
(`docs/SORTED.md`). Transients are `src/coll/transient.zig`
(`docs/TRANSIENT.md`); the in-place edits they run are this module's
(§8.3).

---

### 2. Canonical layout

#### 2.1 Array form (subkind 0)

An array-map or array-set holds up to 8 payloads in association order:
insertion order, a replaced value keeping its position. The order is a
representation detail: it shows in iteration, printing and codec
bytes, never in `=` or `hash`. It indexes nothing by hash, but hashes a key it
adds that may hold a lazy seq (a lazy seq, a list, a vector, a map, a
sorted collection or a record): hashing realizes every lazy seq in it,
so no map or set holds one unrealized (`docs/LAZY.md` §6). A set's
elements were realized when it took them, so a set key is not hashed.

#### 2.2 Trie (subkind 1)

The trie is a function of the key set. Every key sits at the
shallowest node where no other key shares its indexing-hash path
(§5.1), and every node below the root holds at least two keys in its
subtree (§4.3, §5.5). Two trie-backed maps with the same keys therefore
have identical bitmaps at every node and iterate, print and encode in
the same order, whatever their build history, except inside a
collision node (§2.3). `canonicalTrie` checks this layout.

The layout is a representation property, not an equality mechanism:
`=` and `hash` are semantic (§6.1, §7) and compare an array form with a
trie freely, since a trie that shrinks below 9 keys stays a trie
(§5.4).

#### 2.3 Collision nodes

A collision node keeps its entries in association order. A canonical
order would need a total order over arbitrary Values, which nexis does
not define.

---

### 3. Subkinds

| Subkind | Map | Set |
|---|---|---|
| 0 | array-map: ≤ 8 entries inline | array-set: ≤ 8 elements inline |
| 1 | CHAMP root: count and root interior | CHAMP root: count and root interior |
| 2..15 | reserved | reserved |

Every map or set Value carries subkind 0 or 1, and the root accessors
assert it. Interior and collision nodes are allocations of the same
heap kind that no Value points at; no header records which one a node
is. Every walk knows it from the shift it reached the node at: past
`MAX_TRIE_SHIFT` a node is a collision node, otherwise an interior. A
root header's subkind follows from its body size (a CHAMP root body is
16 bytes, which no array body `8 + n·32` or `8 + n·16` can be); this is
how `hashMap`, `equalMap`, `traceMap` and `valueFromMapHeader` read a
bare header.

An empty map or set is a zero-payload array form, freshly allocated by
each `mapEmpty`/`setEmpty`; there is no shared empty singleton.

---

### 4. Body layouts

Every body starts with an 8-byte header and is followed by its
payloads. A payload is an `Entry` (`key: Value, value: Value`, 32
bytes) in a map and a bare key `Value` (16 bytes) in a set. `_pad`
fields are never hashed or compared. Only a root carries metadata (the
header's `meta` slot, SEMANTICS §7); the collector's `markInternal`
skips the `meta` of interior and collision nodes.

#### 4.1 Array body (subkind 0)

`count: u32` (0..8), `_pad: u32`, then `count` payloads in association
order.

#### 4.2 Root body (subkind 1)

`count: u32` (the total over the whole trie), `_pad: u32`, `root_node:
*HeapHeader` (always an interior); 16 bytes. `root_node` is never null:
an empty collection is an array form (§5.6). The root's count makes
`count` O(1) without per-node counts; `assoc` reports through its
recursion whether it added a key. A map or set holds at most 2³² − 1
keys, the most the field holds: adding a key past it, persistent or in
place, fails with `error.OutOfMemory` (out of memory to the language)
and changes nothing.

#### 4.3 Interior node

`data_bitmap: u32`, `node_bitmap: u32`, then `popCount(data_bitmap)`
payloads, then `popCount(node_bitmap)` child pointers. Invariants:

1. `data_bitmap & node_bitmap == 0`: a slot holds at most one payload
   or one child.
2. The body is compact: payloads, then children, with no gaps.
3. Payloads are in ascending slot order: slot `i`'s payload is at
   `popCount(data_bitmap & ((1 << i) - 1))`.
4. Children are in descending slot order: slot `i`'s child is at the
   number of `node_bitmap` bits above `i`.
5. No empty interior exists, and every interior below the root holds at
   least two keys in its subtree. A lone key belongs inline in its
   parent (§5.5); an interior with no payloads and one child is legal
   when that child's subtree holds two or more keys. The root interior
   is exempt: a one-key trie is a root interior holding one payload
   (§5.4).

Together these make the trie canonical (§2.2). `canonicalTrie(v,
elementHash)` checks every one of them, and that each key sits at the
slot its indexing hash selects along its path.

#### 4.4 Collision node

`shared_hash: u32` (the 32-bit indexing hash every key in it shares,
§5.1), `count: u32` (≥ 2), then `count` payloads in association order.
A lookup compares its hash against `shared_hash` before walking the
payloads.

---

### 5. Indexing hash, levels, promotion and dissoc

#### 5.1 Indexing hash

A key's indexing hash is the low 32 bits of `dispatch.hashValue(key)`,
computed once per operation. The module takes `elementHash` as a
callback (§9) and consults it for heap keys only: an immediate key
hashes through `Value.hashImmediate`, which is what `dispatch.hashValue`
computes for it, so a keyword or fixnum key skips the callback. A test
fixture that shapes the indexing hash through `elementHash` must
therefore key by heap values (§12.3).

The hash has a fixed seed, so keys can be chosen to share one indexing
hash: n such keys land in one collision node, a linear list, which
makes each insert and lookup O(n) and building the map O(n²), as in
Clojure. What finding such keys costs depends on the kind. A string,
keyword or symbol takes about 2³² hashes offline per key. A fixnum or
float takes none: its hash is xxHash3's 8-byte path, a bijection of the
64-bit word, plus a constant per kind, so keys with any chosen indexing
hash come from inverting it. Every preimage is a float key (NaN aside)
and about one in 2¹⁶ a fixnum. A char has 2²¹ values to try. So a set
or map built from untrusted numbers (`set`, `frequencies`, `group-by`
or `distinct` over a JSON array; a Nextomic `:find` set) can be made
quadratic, as Clojure's can: its `Murmur3.hashLong` is invertible too.

#### 5.2 Levels

The slot at shift `s` is `(hash >> s) & 0x1F`. Levels 0..5 (shifts 0,
5, …, 25) consume 5 bits each; level 6 (shift 30, `MAX_TRIE_SHIFT`, a
`u8`) consumes the last 2, so only slots 0..3 are reachable there. Keys
whose full 32-bit indexing hashes are equal meet in a collision node
below level 6. The indexing width is fixed at 32 bits.

#### 5.3 Promotion

`assoc` of a new key into an 8-entry array form builds a subkind-1
root holding the nine: they are sorted by slot path and the trie is
built bottom-up, one allocation per node, with the builder that serves
`mapFromEntries` and `setFromElements`. The result is the canonical
trie of the nine keys.

#### 5.4 No demotion

A trie that shrinks below 9 keys stays subkind 1, as Clojure's
`PersistentHashMap.without` does: demotion would churn at the 8/9
boundary. Equal maps can therefore differ in subkind, which §6.1 and §7
handle. A trie left with one key is a root interior holding that one
payload.

#### 5.5 Lone-key pull-up

When `dissoc` leaves a subtree below the root holding one key, that key
moves inline into the parent. If the parent's only content was that
subtree, the parent would hold the lone key itself, so the key passes
further up until it reaches a node with other content or the root. A
collision node left with one key starts the same climb from the bottom.
A subtree emptied entirely is removed from its parent's `node_bitmap`.
Without this rule two equal maps could differ by a lone-key interior
and iterate in different orders.

#### 5.6 Dissoc at the root

Removing a trie's last key returns a fresh empty array form, never a
subkind-1 root with a null `root_node`.

---

### 6. Equality

The category rule (a map is never `=` to a set, a record or a
sequential) is dispatch's (SEMANTICS §3.3); this section is the
same-kind comparison `equalMap`/`equalSet`.

#### 6.1 Same-kind equality

One strategy serves every subkind pair (array/array, trie/trie,
array/trie): the same header is equal; different counts are unequal;
otherwise every entry `(k, v)` of `a` must be found in `b` by `mapGet`
with an `=` value (for a set, every element found by `setContains`).
Collision nodes need no special case. A map value may be nil, so the
lookup must tell an absent key from a nil value (§6.3).

#### 6.2 Key comparison

Key comparison inside the module (`keyEquivalent`) tries two shortcuts
before `elementEq`: bit identity (same tag and payload), and, when
either key is an immediate, `Value.equalImmediate` inline, since an
immediate is `=` only to an immediate of its own kind (SEMANTICS
§3.3). Both are exact: two keywords are `=` exactly when their ids
are equal, and a keyword or fixnum key never reaches the callback.

#### 6.3 `MapLookup`

`mapGet` returns `MapLookup`, a union of `absent` and `present: Value`,
not `?Value`: nil is a legal map value, and absence is ordinary flow,
not a contract violation. `setContains` returns a bool; `setGet`
returns the element the set holds equal to the one asked for (which
may differ from it, a list for a vector), or null. The stdlib
natives map `absent` to nil or the caller's default.

---

### 7. Hash

#### 7.1 Entry hash (map)

`entryHash(k, v) = combineOrdered(combineOrdered(ordered_init,
hashValue(k)), hashValue(v))`: two ordered combines, no
`finalizeOrdered`, no domain mix (SEMANTICS §3.2). Swapping a key and
its value changes the entry hash.

#### 7.2 Aggregate hash

`hashMap` folds every entry hash, `hashSet` every element's
`hashValue`, with `combineUnordered` from `unordered_init`, then
`finalizeUnordered(acc, count)`. Every representation iterates every
payload through the same fold, so the result is independent of subkind
and layout, and `dispatch.hashValue` mixes the kind's domain byte in on
top.

#### 7.3 Caching

`hashMap` and `hashSet` return the aggregate truncated to `u32` and
cache it in the root header when nonzero (the HEAP.md cache rule).
Interior and collision nodes cache nothing.

---

### 8. Public API (`src/coll/champ.zig`)

`ElementHash` is `*const fn (Value) u64` and `ElementEq` is `*const fn
(Value, Value) bool`; callers pass `&dispatch.hashValue` and
`&dispatch.equal` (§9). `h` is a root header.

| Map | Set | Contract |
|---|---|---|
| `mapEmpty(heap)` | `setEmpty(heap)` | a fresh empty array form |
| `mapFromEntries(heap, entries, eh, ee)` | `setFromElements(heap, elems, eh, ee)` | §8.1 |
| `mapAssoc(heap, m, k, v, eh, ee)` | `setConj(heap, s, e, eh, ee)` | §8.1 |
| `mapDissoc(heap, m, k, eh, ee)` | `setDisj(heap, s, e, eh, ee)` | §8.1 |
| `mapGet(m, k, eh, ee) MapLookup` | `setContains(s, e, eh, ee) bool`, `setGet(s, e, eh, ee) ?Value` | §6.3 |
| `mapFind(m, k, eh, ee) ?Entry` | | The stored entry, its key as the map holds it (`find`) |
| `mapCount(m)`, `mapIter(m)` → `MapIter` | `setCount(s)`, `setIter(s)` → `SetIter` | `next()` gives `?Entry` / `?Value` in iteration order (§8.1) |
| `hashMap(h, eh)` | `hashSet(h, eh)` | §7 |
| `equalMap(a, b, eh, ee)` | `equalSet(a, b, eh, ee)` | §6.1; header arguments |
| `traceMap(h, visitor)` | `traceSet(h, visitor)` | GC trace: every key and value, every internal node through `markInternal` |
| `valueFromMapHeader(h)` | `valueFromSetHeader(h)` | the Value for a root header (`docs/TRANSIENT.md` §8) |
| `mapCollisionCount(m, hash32) ?u32` | `setCollisionCount(s, hash32) ?u32` | tests: the collision node's count along `hash32`, or null (§12.3) |

`canonicalTrie(v, eh)` takes a map or a set (§4.3); `Entry`,
`MapLookup`, `MAX_TRIE_SHIFT` (30), `array_map_max` (8) and the subkind
constants are public. Every constructor can fail only with
`error.OutOfMemory`.

#### 8.1 Update semantics

- `mapAssoc` of a present key: a bit-identical value returns `m`
  itself; any other value, even an `=` one, is stored, the key object
  already in the map kept (Clojure's behaviour) and the count
  unchanged. `setConj` of a present element returns `s`, keeping the
  stored element.
- `mapAssoc`/`setConj` of a new key: an array form below 8 appends; at
  8 it promotes (§5.3); a trie inserts along the key's path.
- `mapDissoc`/`setDisj` of an absent key returns the argument itself.
  Removing a present key applies §5.4 to §5.6.
- `mapFromEntries`/`setFromElements` return what a left fold of
  `mapAssoc`/`setConj` from empty returns (same subkind, same trie,
  same iteration order) and never fail on duplicates: a later entry's
  value wins, the first key object and its position stay. Up to eight
  payloads make the array form as the fold makes it, each compared with
  those kept and none hashed to index (§2.1). More are sorted by slot
  path, on one 64-bit key each (the bit-reversed indexing hash above the
  input position), equal keys merged, and each node allocated once.
- **Iteration order.** An array form iterates in association order. A
  trie iterates depth first from the root: each node's payloads in
  ascending slot order, then its children in their stored, descending
  slot order; a collision node's payloads in association order.

#### 8.2 Nil

Nil is a legal key, a legal value and a legal set element: `(assoc {}
nil nil)` is `{nil nil}`, `(contains? {nil nil} nil)` and `(contains?
#{nil} nil)` are true. Its hash and equality come from dispatch; the
module has no nil case.

#### 8.3 In-place edits

A transient's edit (`docs/TRANSIENT.md` §1) is two calls:
`mapLocate`/`setLocate` finds where a key is or would go, doing every
hash and comparison and changing nothing, and returns a `MapSpot` or
`SetSpot` (`mapSpotPresent`, `mapSpotValue` read it);
`mapPut`/`setPut` then stores, or `mapDrop`/`setDrop` removes, at that
spot in a collection whose root the edit owns, and return the root
afterwards. They rewrite the nodes whose header `hash` holds the edit
token and copy any other node on the path, stamping the copy; an
insert into an owned node grows it in place when its block has room
(`Heap.resizeInPlace`), and a node an edit grows into a new block
keeps two payloads of spare room there. The result has the layout
`mapAssoc` and `mapDissoc` give (§2.2, §5.3-§5.6). `copyRoot` copies
a root for a transient to own.

#### 8.4 Panics

`mapGet`, `mapCount`, `mapAssoc` and `mapDissoc` (and their set
counterparts) assert a map (set) Value of subkind 0 or 1 in safe
builds; an absent key is never a panic. The nil and wrong-kind cases of
the language surface are the stdlib natives'.

---

### 9. Dispatch

`dispatch` calls `hashMap`/`hashSet` from `heapHashBase` and
`equalMap`/`equalSet` from `equal`; the category and domain rules are
SEMANTICS §3.3. `champ.zig` never imports `dispatch`: hashing and
comparison of arbitrary Values arrive as the `elementHash`/`elementEq`
callbacks, so the module is a one-way terminal of the import graph.

---

### 10. Implementation traps

1. **Bitmap rank.** Payloads count set bits below the slot; children
   count set bits above it (§4.3). An off-by-one misroutes every slot
   but the first.
2. **Disjoint bitmaps.** A slot set in both bitmaps is read two ways
   and silently drops or duplicates entries.
3. **Dissoc canonicality.** Skipping the lone-key pull-up or leaving an
   emptied subtree in the parent breaks §2.2 (§5.5).
4. **Collision placement.** Two keys still sharing a slot at shift 30
   go into a collision node; there are no more bits to split on.
5. **Absence in a trie.** A lookup follows the child pointer of an
   occupied node slot to its end; only an empty slot, a payload with a
   different key, or a collision node with another `shared_hash` means
   absent.

---

### 11. One trie for both kinds

`Trie(P, kind)` is generic over the payload: `MapTrie` is
`Trie(Entry, .persistent_map)`, `SetTrie` is `Trie(Value,
.persistent_set)`. The payload type decides how its key is read,
whether a store over an equal key changes anything (a set's never
does; a map's does unless the value is bit-identical), and how it
hashes (§7.1 or the element hash). Layouts, bitmap rules, promotion,
dissoc, the builder, the iterator and the trace are shared, and the
public `map*`/`set*` names are the two instances' operations, most of
them declared as the operation itself. Every persistent path copy goes through one primitive,
`withSlot`: a copy of an interior with one slot made empty, a payload
or a child. An in-place edit (§8.3) copies a node on its path that it
does not own whole (`ownPath`), then rewrites the owned interior where
it stands: a payload into an empty slot when its block has room
(`insertData`, else a copy through `withSlot`), a payload into a child
(`dataToChild`) or a payload out (`removeData`), each a pair of moves,
which a general rewrite in their place does not match. A lone payload
pulled up into a child's slot (§5.5) is a copy through `withSlot`.
Lookup is an iterative descent; insert and remove recurse at most
eight levels.

---

### 12. Tests

`test/prop/champ.zig` holds the map and set properties and the collision
fixtures (which key by heap strings and pin the low 32 bits of their hash
through the `elementHash` callback, §5.1); the inline tests of `champ.zig`
cover the body layouts, promotion and the shortcuts.
