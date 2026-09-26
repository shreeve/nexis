## SORTED.md — Sorted Map and Set Heap Kinds

The contract for the `sorted_map` and `sorted_set` heap kinds
(`src/coll/sorted.zig`) and their language surface: Clojure's
`sorted-map`, `sorted-set`, `subseq` and `rseq`, on a persistent
weight-balanced tree. Kind numbers: `docs/VALUE.md` §2.2 (41, 42).
Header bits: `docs/HEAP.md`. Equality category and hash domain:
`docs/SEMANTICS.md` §3.3 (the hash map's and hash set's). Serializable
in the natural order only: `docs/CODEC.md` §2.8, §3. The decision to
add the kinds: PLAN Amendment Log, 2026-09-26.

---

### 1. Scope

A sorted map or set holds its entries in the order of a comparator,
fixed when the collection is made: the natural order (§6), or a
function given to `sorted-map-by` / `sorted-set-by`. Costs:

| Operation | Cost |
|---|---|
| `assoc`, `dissoc`, `conj`, `disj` | O(log n) comparisons; copies the O(log n) nodes on the path |
| `get`, `contains?`, `find`, calling it, a keyword lookup | O(log n) comparisons, no allocation |
| `count`, `empty?`, `first` of the collection's seq | O(1), O(1), O(log n) |
| `seq`, `rseq`, `keys`, `vals`, `reduce`, `reduce-kv`, printing | O(n), in order; `rseq` in reverse |
| `subseq`, `rsubseq` | O(log n) to the bound, then O(1) per entry returned |
| `=` against a hash collection, `hash` | O(n) with no comparator call (§7) |

**Absent, as in Clojure.** Transients (`(transient (sorted-map))` is
`:kind-mismatch`), `nth`, `peek`, `pop` and sequential destructuring
of a sorted set (`(let [[a] (seq s)] ...)` destructures its seq).

**Differences.** A sorted map is not a metadata map (`with-meta`
takes a hash map). A protocol extended to `:map` or `:set` does not
reach a sorted collection, which has kinds of its own: extend
`:sorted_map` or `:sorted_set` (`docs/PROTOCOLS.md` §4.3). Functions
that build a fresh map or set (`select-keys`, `set`, `zipmap`,
`frequencies`, `update-vals`, `nexis.set/union`) build a hash one, as
Clojure's `select-keys` and `set` do.

---

### 2. Layout

Every sorted map or set Value is subkind 0 and points at a root block
of its kind:

| Offset | Field | Meaning |
|---|---|---|
| 0 | `comparator: Value` | the ordering function; nil for the natural order |
| 16 | `tree: ?*HeapHeader` | the root node; null when empty |
| 24 | `_pad` | layout only |

A node is a block of the same kind that no Value points at:

| Offset | Field | Meaning |
|---|---|---|
| 0 | `left`, 8 `right: ?*HeapHeader` | the subtrees of lesser and greater keys |
| 16 | `size: u64` | nodes in this subtree, this one included; the root's is the count |
| 24 | `key: Value` | |
| 40 | `val: Value` | a map's value; a set's node ends at offset 40 |

Only the root carries metadata; the collector reaches the nodes
through `markInternal` (`docs/GC.md` §5). The comparator is a Value
the root holds, so the collector keeps a user function alive as long
as a collection ordered by it.

---

### 3. The tree

The tree is Adams' weight-balanced tree with the parameters Haskell's
`Data.Map` uses, `delta = 3` and `ratio = 2` (Hirai and Yamamoto
proved them the one integer pair that keeps the invariant through
single inserts and deletes). **Invariants**, checked after every step
of `test/prop/sorted.zig`:

1. Every node's `size` is `size(left) + size(right) + 1`.
2. For a node whose subtrees hold two or more nodes together, neither
   holds more than `delta` times the other.
3. An in-order walk yields keys in strictly ascending comparator order:
   no two keys of one collection compare equal.
4. The height is below 128. The smallest tree of height h grows by
   4/3 per level, so height 128 needs more than 2^52 nodes; an
   iterator's path is a fixed 128-entry array.

**Updates.** An insert or a delete walks from the root comparing the
key at each node, then rebuilds the nodes of its path bottom-up with
`balance`, which makes a node over two subtrees and rotates once
(single or double, chosen by `ratio`) when one side has outgrown
`delta` times the other. A delete joins the removed node's subtrees
through the larger side's extreme node. Every comparison happens on
the way down, before the first allocation (§8). Nothing off the path
is copied: an update shares every other node with the collection it
came from.

An update that changes nothing returns the collection itself: `assoc`
of a key to a bit-identical value, `conj` of a present element,
`dissoc` or `disj` of an absent one. A key already present keeps the
key object the tree holds and takes the new value, as Clojure's
`PersistentTreeMap` does. `conj`, `assoc`, `dissoc`, `disj` and `empty`
keep the collection's comparator and metadata (SEMANTICS §7).

---

### 4. Comparators

`(sorted-map-by f & kvs)` and `(sorted-set-by f & xs)` order by `f`,
coerced as Clojure's `AFunction.compare` coerces a function:

- a number: its sign, after truncation toward zero (a float between -1
  and 1 is equal, as Java's `intValue` makes it); NaN is equal;
- `true`: less; `false` or nil: `(f b a)` decides, truthy meaning
  greater and falsy equal, so a predicate such as `<` or `>` is a
  comparator;
- anything else: `:kind-mismatch`.

`f` may be any callable. `(sorted-map-by compare ...)` is the natural
order itself, stored as nil, so it serializes and compares in lock
step with other natural-order collections. A comparator that throws
aborts the operation with its throw and leaves the collection as it
was. Two keys the comparator calls equal are one key: `(sorted-set-by
(fn [a b] (compare (count a) (count b))) "ab" "cd")` is `#{"ab"}`.

---

### 5. Walks

`Iter` walks the tree in order, ascending or descending, holding the
path from the root to the next entry (at most 128 nodes); a full walk
is O(n). `Iter.from(v, key, ascending, cmp)` is Clojure's `seqFrom`:
ascending, the entries from the least key not below `key`; descending,
from the greatest key not above it. `Cursor` walks ascending by
position through the subtree sizes, O(log n) a step in a few words;
the codec keeps one per open container. `first`, `last` and
`entryAt(v, i)` answer in O(log n).

`subseq` and `rsubseq` are Clojure's:

- `(subseq sc test key)`, `test` one of `<` `<=` `>` `>=`: the entries
  whose key satisfies `(test (cmp k key) 0)`, ascending. For `>` and
  `>=` the walk starts at `key`; for `<` and `<=` it starts at the
  least entry and stops at the first key that fails.
- `(subseq sc start-test start-key end-test end-key)`: from
  `start-key`, while the end test holds.
- `rsubseq` is the same, descending: `<` and `<=` start at the key,
  `>` and `>=` at the greatest entry.

A test that is not one of the four is called as `(test (cmp k key) 0)`
and, like Clojure, never chooses the starting point. Each returns a
list of entries (`[k v]` for a map), or nil when nothing satisfies it.
`(rseq sc)` is every entry, greatest first; nil when empty.

---

### 6. The natural order

`sorted.naturalOrder(interner, a, b)` is Clojure's `compare`, and the
`compare` native, `sort` and `sort-by` use it too:

| Operands | Order |
|---|---|
| nil against anything | nil first; `(compare nil nil)` is 0 |
| two numbers | across the tower: two integers exactly, at any size; with a float operand, both as f64; NaN is equal to every number, as neither `<` nor `>` holds |
| two booleans | false before true |
| two strings | by UTF-8 bytes, which is code-point order |
| two keywords, two symbols | an unqualified name before a qualified one, then by namespace, then by name, bytewise |
| two chars | by scalar |
| two vectors | the shorter first, then element by element |
| anything else | `:kind-mismatch`: two kinds apart, or a kind with no order (lists, maps, sets, functions, ...) |

A natural-order collection's keys must be mutually comparable: `(assoc
(sorted-map 1 :a) :k :b)` is `:kind-mismatch`, as Clojure's
`ClassCastException`. A collection of one entry holds any key, since
nothing is compared. The natural order equates `1` and `1.0`, so a
sorted map holds one of them where a hash map holds both.

---

### 7. Equality and hash

A sorted map is a map and a sorted set a set (SEMANTICS §2.6): `(=
(sorted-map 1 :a) {1 :a})` is true, the two hash alike, and a sorted
collection is equal to one ordered by another comparator with the same
entries. `hashOf` is `champ`'s formula (the unordered sum of the entry
or element hashes, finalized with the count, cached in the root
header), and `dispatch` mixes in the hash kind's domain byte, 18 or
19.

`=` never calls a comparator, which may be user code and may throw.
Between a sorted collection and a hash one, `dispatch` walks the sorted
side and looks each key up in the hash side by hash; two natural-order
collections walk in lock step; two whose orders differ look up through
one side's entries sorted by key hash (scratch memory outside the
collected heap). A hash check first answers most unequal pairs and,
short of a hash collision, the one case those walks would pass: a user
order that keeps two `=` keys apart.

---

### 8. Rooting and errors

A comparator call re-enters the VM and may collect (`docs/GC.md`
§11.5). The tree module compares only on the way down, before it
allocates, so a node it builds is never held in a Zig local across a
comparator call. The natives that make several updates in one call
(`sorted-map-by`, `sorted-set-by`, `conj` and `into` of many entries,
`assoc` and `dissoc` of several keys, `select-keys` of a sorted map)
push each intermediate collection on the native's root scope, and
`into` roots the entries it collected before the first update; the
natives that collect entries for a range (`subseq`, `rsubseq`) gather
the tree's nodes, all reachable from the argument, and build the
result only after the last comparison. `NEXIS_GC_STRESS=1` exercises
each (`test/integration/eval_pipeline.zig`, "gc: sorted").

An incomparable key is `:kind-mismatch`; a comparator's throw
propagates unchanged; a key nested too deeply to compare is
`:stack-overflow` (the natural order checks the stack guard at each
level).

**A caller without a VM.** `vm.lookup` and `vm.callLookupIn` given no
VM find a sorted key by `=` in a linear walk instead of through the
comparator; the Nextomic query hook passes its VM.

**Forms, metadata and tx-data.** A macro may return a sorted
collection in the natural order, and quoting one yields it
(`docs/MACROEXPAND.md` §1.2); a sorted map may be metadata
(`docs/SEMANTICS.md` §7) and a Nextomic entity map
(`docs/NEXTOMIC.md` §3).

---

### 9. Tests

`test/prop/sorted.zig`: P1 random updates of maps and sets against a
sorted-array model, the invariants, count, lookups and both walk
directions checked after every step; P2 a kept version unchanged by
later updates; P3 the walk from a random bound, both ways; P4 a
descending comparator and one that equates keys; P5 `=` and hash
agreement with hash maps and sets and across comparators, and one
change breaking it; P6 the natural order over strings, keywords and
vectors; P7 the collector keeping the tree through the root alone and
sweeping a dropped path; P8 the codec round trip, equal, hash-equal,
sorted and byte-stable. Inline tests in `sorted.zig` pin the shape
through 2000 random and 4096 ascending inserts, the walks and the
natural order; `codec.zig` the wire format and its refusals;
`eval_pipeline.zig` the language surface ("sorted collections: ...")
and the rooting under the collector.
