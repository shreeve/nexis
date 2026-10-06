## TRANSIENT.md — Transients

The contract for the `.transient` heap kind (`src/coll/transient.zig`)
and its language surface (`transient`, `persistent!` and the `!`
operations in `src/stdlib.zig`). Kind number: `docs/VALUE.md` §2.2.
Ownership compared with Clojure's:
`CLOJURE-REVIEW.md` §1.2, §3.5.

---

### 1. Model: in-place edits of owned nodes

A transient is a small block `{owner_token, inner_header}`: an edit
token and the root of the collection it is building, a root of its
own (`transient` copies the source's root, without metadata). A node
of the collection whose header `hash` holds the token is the
transient's; any other node may be shared with persistent
collections. An edit writes the root and the nodes it owns in place,
and copies any other node on its path once, stamping the copy with
the token, before writing it (Clojure's `ensureEditable`). A vector
transient appends into a tail it owns while it has room, copying it
into a block twice the size when it has none, as `conj` does
(VECTOR.md §2), pushes a full tail into the trie as a leaf, starting
the next with room for 32, and writes a leaf or interior it owns
directly; a map or set transient replaces a value where it lies,
inserts a payload into an owned node that has room in its block
(`Heap.resizeInPlace`, `docs/HEAP.md` §3), and gives a node it grows
two payloads of spare room so the next inserts land in place. A
persistent collection never changes: no transient owns a node it can
reach.

The layout a transient builds is the one the persistent operations
build for the same contents: the same vector trie (VECTOR.md §3), the
same canonical CHAMP trie with its promotion at nine keys and its
lone-key pull-up (CHAMP.md §2.2, §5). `persistent!` zeroes the token,
so no edit reaches those nodes again, and returns the root.

A map or set edit is two steps: it locates the key, doing every hash
and comparison, then rewrites the nodes; a lookup that hashed or
compared past the stack guard changes nothing (§6). Every edit
allocates what it needs before it writes a node the collection
reaches, so a failed allocation leaves the elements as they were.

`frequencies`, `group-by` and `conj` of four or more elements onto a
vector, hash map or hash set (and so `into`) build their result
through a transient.

**Absent.** Transient lists (a `cons` is already O(1)), transient typed
vectors (a typed vector takes no updates, `docs/TYPED_VECTOR.md` §1),
and an owner-mismatch check between isolates (there is one isolate).

---

### 2. Subkinds

A local enum; it does not mirror the inner collection's kind number.

| Subkind | Wraps |
|---|---|
| 0 | `.persistent_map` |
| 1 | `.persistent_set` |
| 2 | `.persistent_vector` |

No other kind can be wrapped. The wrapper's subkind fixes the inner
root's kind, so no operation inspects the inner header's kind.

---

### 3. Wrapper layout

Body 16 bytes: `owner_token: u64` at offset 0 (0 = frozen, nonzero =
active: the edit token, 26 bits, §4) and `inner_header: *HeapHeader` at
offset 8, the root the transient owns, never null. An edit that
outgrows an array form, promotes it or empties a trie replaces the
root. A transient never carries metadata.

---

### 4. Edit token

Tokens come from a counter on the heap, `Heap.edit_clock`, which
`transient` advances up to `edit_token_max` (2²⁶ − 1); 0 is reserved
for "frozen" and for the nodes no transient owns (a fresh block's
`hash` is 0). An internal node of a vector, map or set caches no hash,
so the high 26 bits of its `hash` field hold the token of the
transient that owns it (`docs/HEAP.md` §1). A token is
never reissued while a node carries it: when the clock would wrap,
every map, set and vector block of the heap forgets its token (a root
forgets its cached hash, recomputed on the next use) and every active
transient takes a new token from 1, so no transient edits a node
another one owned.

That reaches every token because a token lives only in its wrapper and
on the nodes it stamps: no code outside `transient.zig` reads one, and
each edit reads its wrapper's token at the edit, after anything it
calls that can issue a token. A native that grows a vector of its own
inside a transient map's values (`group-by`'s buckets) does it through
`vectorConjUnderBang`, which reads the map's token the same way. A
token kept across a call that can issue one would be stale after a
wrap: the nodes it stamped would carry a token the clock hands out
again, and the transient taking it would edit them in place, inside a
persistent value by then. The wrap's tests set `edit_clock` near
`edit_token_max` instead of issuing 2²⁶ tokens.

The runtime is single-threaded per VM, so a nonzero token is an
aliveness signal: `persistent!` is the only way a transient loses its
owner.

---

### 5. States

| State | Token | Behaviour |
|---|---|---|
| active | nonzero | every operation allowed; made by `transient` |
| frozen | 0 | every operation, reads included, is rejected; made by `persistent!` |
| dead | — | unreachable; the sweep frees the wrapper |

`persistent!` zeroes the token and returns the inner collection as a
persistent Value, safe to share. It leaves `inner_header` in place, so
a frozen wrapper still traces its inner root (§10).

---

### 6. Errors

| Zig error | Raised when | The language sees |
|---|---|---|
| `TransientFrozen` | any operation on a frozen wrapper | `:transient-used-after-persistent` |
| `TransientKindMismatch` | a non-transient Value, or the wrong family (`dissoc!` on a vector transient) | `:kind-mismatch` |
| `InvalidTransientInner` | `transient` of anything but a hash map, hash set or vector (a sorted collection has no transient, as in Clojure) | `:kind-mismatch` |
| `IndexOutOfBounds` | `pop!` of an empty vector; `assoc!` past the count | `:index-out-of-bounds` |

These are ordinary branches, checked in every build mode. The stdlib
also checks the family before calling in (`transientFailure` in
`src/stdlib.zig` maps the Zig errors).

A `!` call of several operands is a loop of edits, as Clojure's
`assoc!`, `dissoc!` and `disj!` of several keys are. It checks the shape
of every operand before its first edit, so an operand of the wrong
shape changes nothing: a vector `assoc!` checks every index
(`:kind-mismatch`, `:index-out-of-bounds`), a map `conj!` every operand
(a `[k v]` vector, a map, a record or nil; else `:arity-mismatch` or
`:kind-mismatch`). A map or set edit changes nothing unless its lookup
ran clean: one whose key hashed or compared past the stack guard
raises `:stack-overflow` (`docs/SEMANTICS.md` §2.7), and the call stops
there with the edits before it kept, as a loop that throws keeps them.
Memory running out in the middle of a call is not undone either: the
error is not catchable (`docs/VM.md` §13), and the edits done before it
stay.

---

### 7. API

**Language surface** (`src/stdlib.zig`). Every `!` returns the same
wrapper it was given; the source collection is never changed.

| Form | Meaning |
|---|---|
| `(transient coll)` | an active transient of a hash map, hash set or vector |
| `(persistent! t)` | the collection; `t` is frozen |
| `(conj! t x & xs)` | vector: append; set: add; map: `x` as `conj` onto a map takes it, a `[k v]` vector, a map or record whose entries are all put, or nil (nothing). `(conj!)` is a new transient vector, `(conj! t)` is `t` |
| `(assoc! t k v & kvs)` | map: put; vector: replace index `k`, or append when `k` is the count |
| `(dissoc! t k & ks)` | map only |
| `(disj! t x & xs)` | set only |
| `(pop! t)` | vector only: without its last element |
| `count`, `empty?`, `get`, `contains?` | on any transient; `get` of a vector transient takes an index |
| `nth` | on a vector transient |

A transient map, set or vector is called, and looked up by a keyword,
as its persistent kind is (`((transient {:a 1}) :a)` and `(:a
(transient {:a 1}))` are 1; `((transient [5 6]) 1)` is 6). It is not
seqable (`seq` of one is `:kind-mismatch`).

```clojure
(persistent! (reduce conj! (transient []) (range 5)))   ;=> [0 1 2 3 4]
(let [t (transient {:a 1})]
  (persistent! (dissoc! (assoc! t :b 2 :c 3) :a)))      ;=> {:b 2, :c 3}
(let [t (transient [])]
  (persistent! t)
  (try (conj! t 1) (catch any e e)))                    ;=> :transient-used-after-persistent
```

**Zig API** (`src/coll/transient.zig`). Map and set operations take the
`elementHash`/`elementEq` callbacks their persistent counterparts take,
and the edits the overflow count (`dispatch.overflowCount`) they check
their lookup against; mutating operations take the heap and return the
same transient.

| Family | Functions |
|---|---|
| wrap | `transientFrom(heap, v)`, `persistentBang(t)` |
| map (0) | `mapAssocBang`, `mapDissocBang`, `mapLocateBang` and `mapPutBang` (one lookup for a read then a store), `vectorConjUnderBang` (a vector inside the map's values, grown under its token, §4), `mapGetBang` (a `champ.MapLookup`), `mapCountBang` |
| set (1) | `setConjBang`, `setDisjBang`, `setContainsBang`, `setCountBang` |
| vector (2) | `vectorConjBang`, `vectorOpenTailBang` and `vectorCloseTailBang` (a native's builder: 32 slots opened past a full tail and written in place, then the tail's length, `vector.openTailInPlace`), `vectorAssocBang` (appends at `idx == count`), `vectorPopBang`, `vectorNthBang`, `vectorCountBang` |
| GC | `trace(h, visitor)` |

The module imports `champ.zig` and `vector.zig`, never `dispatch`;
`dispatch.zig`, `gc.zig`, `codec.zig` and `stdlib.zig` import it.

---

### 8. The collection seam

Each collection module owns its in-place edits and the Value for a
raw root: `vector.copyRoot`, `conjInPlace`, `openTailInPlace`, `closeTailInPlace`,
`assocInPlace`, `popInPlace` and `valueFromVectorHeader`; `champ.copyRoot`,
`mapLocate`/`setLocate`, `mapPut`/`setPut`, `mapDrop`/`setDrop` and
`valueFromMapHeader`/`valueFromSetHeader` (which infer the array-map
or CHAMP subkind from the body). The transient module calls only these
and never reads a collection's body.

---

### 9. Equality, hash, print, codec, metadata

- **Equality and hash** (SEMANTICS §3.3): identity. A transient is `=`
  only to itself, never to another wrapper of the same collection nor
  to a persistent collection, and hashes by address, so it can be a
  map key.
- **Print**: `#<transient>`; it does not read back.
- **Codec**: not serializable (`docs/CODEC.md` §3); a transient inside
  a durable value is `:unserializable`.
- **Metadata**: `with-meta` is `:kind-mismatch`; `meta` is nil
  (SEMANTICS §7). `transient` holds a copy of the collection's root
  without its metadata, so `persistent!` returns none, as in Clojure.

---

### 10. GC

`trace` marks `inner_header`, the transient's only outgoing reference,
whether it is active or frozen (`docs/GC.md` §5). A transient that is
the sole holder of its collection keeps it alive. The collector knows
nothing of tokens: an owned node is an ordinary block.

---

### 11. Testing

`test/prop/transient.zig`: T1a-T1d equivalence (random edit sequences
through a transient and through the persistent operations give `=` and
hash-equal results, for maps, sets and vectors, T1d with random
`conj!`/`assoc!`/`pop!`); T2a-T2d ownership (a frozen transient rejects
every operation; the wrong family gives `TransientKindMismatch`);
T3a-T3b the source collection is unchanged; T4, T4b the root survives
collection through an active or a frozen transient; T5a-T5d every
persistent map, set and vector any round produced keeps its contents,
canonical layout and hash while later transients over it and its
relatives, two at once, edit in place, through collision nodes and
across the vector's trie boundaries, with collections in between; T6
the edit clock's wrap. Inline tests in `transient.zig` cover the
wrapper and that an edit of owned nodes allocates nothing;
`test/integration/eval_pipeline.zig` ("transients", the wrap of the
clock under `group-by` and under a `!` call that raises, and the `gc:`
tests of `group-by` and transient builds under the stress policy)
covers the language surface.
