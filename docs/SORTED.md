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
function. The module provides construction, `assoc`, `conj`,
`without`, `find`, `first`, `last`, `entryAt`, the walks (§5), and
the hash, equality and trace entry points. Costs:

| Operation | Cost |
|---|---|
| `assoc`, `conj`, `without` | O(log n) comparisons; copies the O(log n) nodes on the path |
| `find` | O(log n) comparisons, no allocation |
| `count`; `first`, `last`, `entryAt` | O(1); O(log n) |
| a whole walk, `hashOf` | O(n), in order |
| `Iter.from` | O(log n) to the bound, then O(1) per entry |
| `=` against a hash collection | O(n) with no comparator call (§7) |

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

The module takes the order as a Zig value with a `pub const Error` and
an `order(a, b) Error!std.math.Order` method: `Natural` (§6), or a
comparator of the caller's. The root holds a comparator Value (nil for
the natural order) for the caller to read back through
`comparatorOf`; the module never calls it. Two keys the order calls
equal are one key.

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

---

### 6. The natural order

`sorted.naturalOrder(interner, a, b)` is Clojure's `compare`:

| Operands | Order |
|---|---|
| nil against anything | nil first; `(compare nil nil)` is 0 |
| two numbers | across the tower: two integers exactly, at any size; with a float operand, both as f64; NaN is equal to every number, as neither `<` nor `>` holds |
| two booleans | false before true |
| two strings | by UTF-8 bytes, which is code-point order |
| two keywords, two symbols | an unqualified name before a qualified one, then by namespace, then by name, bytewise |
| two chars | by scalar |
| two vectors | the shorter first, then element by element |
| anything else | `KindMismatch`: two kinds apart, or a kind with no order (lists, maps, sets, functions, ...) |

A natural-order collection's keys must be mutually comparable, as
Clojure's `ClassCastException` requires: an insert that compares a
keyword with a number is `KindMismatch`. A collection of one entry
holds any key, since nothing is compared. The natural order equates
`1` and `1.0`, so a sorted map holds one of them where a hash map
holds both.

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

### 8. Rooting

A comparator that is user code re-enters the VM and may collect
(`docs/GC.md` §11.5). The tree module compares only on the way down,
before it allocates, so a node it builds is never held in a Zig local
across a comparator call. The natural order checks the stack guard at
each level: a key nested too deeply to compare is `StackOverflow`.

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
natural order; `codec.zig` the wire format and its refusals.
