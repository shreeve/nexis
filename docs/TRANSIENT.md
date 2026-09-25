## TRANSIENT.md — Transient Wrappers

The contract for the `.transient` heap kind (`src/coll/transient.zig`)
and its language surface (`transient`, `persistent!` and the `!`
operations in `src/stdlib.zig`). Kind number: `docs/VALUE.md` §2.2.
Governing decision: PLAN §9.4. Ownership compared with Clojure's:
`CLOJURE-REVIEW.md` §1.2, §3.5.

---

### 1. Model: shallow wrappers

A transient is a thin wrapper `{owner_token, inner_header}` around a
persistent map, set or vector. Each `!` operation calls the persistent
operation (`champ.mapAssoc`, `champ.setConj`, `vector.conj`,
`vector.pop`, …) on the inner collection and stores the new root in the
wrapper's `inner_header`, in place. **A transient operation costs what
the persistent one costs, plus a wrapper check**: transients give
nexis Clojure's `transient`/`persistent!` API and its ownership
discipline, not its speed-up. Node-level in-place editing (per-node
owner tags) is absent; the wrapper layout and the ownership rules do
not depend on it.

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
active) and `inner_header: *HeapHeader` at offset 8, the current
persistent root, never null. A wrapper never carries metadata.

---

### 4. Owner token

Tokens come from a private process-wide `u64` counter that starts at 1
(`issueOwnerToken`); 0 is reserved for "frozen". No API issues or reads
a token. The runtime is single-threaded per VM, so a nonzero token is
an aliveness signal: `persistent!` is the only way a transient loses
its owner. Exhaustion of the counter is not handled (2⁶⁴ issues).
`TransientWrongOwner` is in the error set for an isolate-epoch check;
no code path returns it.

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
| `InvalidTransientInner` | `transient` of anything but a map, set or vector | `:kind-mismatch` |
| `IndexOutOfBounds` | `pop!` of an empty vector; `assoc!` past the count | `:index-out-of-bounds` |
| `TransientWrongOwner` | never (§4) | — |

These are ordinary branches, checked in every build mode. The stdlib
also checks the family before calling in (`transientFailure` in
`src/stdlib.zig` maps the Zig errors).

---

### 7. API

**Language surface** (`src/stdlib.zig`). Every `!` returns the same
wrapper it was given; the source collection is never changed.

| Form | Meaning |
|---|---|
| `(transient coll)` | an active transient of a map, set or vector |
| `(persistent! t)` | the collection; `t` is frozen |
| `(conj! t x & xs)` | vector: append; set: add; map: `x` is a `[k v]` vector. `(conj!)` is a new transient vector, `(conj! t)` is `t` |
| `(assoc! t k v & kvs)` | map: put; vector: replace index `k`, or append when `k` is the count |
| `(dissoc! t k & ks)` | map only |
| `(disj! t x & xs)` | set only |
| `(pop! t)` | vector only: without its last element |
| `count`, `get`, `contains?` | on any transient; `get` of a vector transient takes an index |
| `nth` | on a vector transient |

A transient is not callable and not seqable (`seq` of one is
`:kind-mismatch`).

```clojure
(persistent! (reduce conj! (transient []) (range 5)))   ;=> [0 1 2 3 4]
(let [t (transient {:a 1})]
  (persistent! (dissoc! (assoc! t :b 2 :c 3) :a)))      ;=> {:b 2, :c 3}
(let [t (transient [])]
  (persistent! t)
  (try (conj! t 1) (catch any e e)))                    ;=> :transient-used-after-persistent
```

**Zig API** (`src/coll/transient.zig`). Map and set operations take the
`elementHash`/`elementEq` callbacks their persistent counterparts take;
mutating operations take the heap and return the same wrapper Value.

| Family | Functions |
|---|---|
| wrap | `transientFrom(heap, v)`, `persistentBang(t)` |
| map (0) | `mapAssocBang`, `mapDissocBang`, `mapGetBang` (a `champ.MapLookup`), `mapCountBang` |
| set (1) | `setConjBang`, `setDisjBang`, `setContainsBang`, `setCountBang` |
| vector (2) | `vectorConjBang`, `vectorAssocBang` (appends at `idx == count`), `vectorPopBang`, `vectorNthBang`, `vectorCountBang` |
| GC | `trace(h, visitor)` |

The module imports `champ.zig` and `vector.zig`, never `dispatch`;
`dispatch.zig`, `gc.zig`, `codec.zig` and `stdlib.zig` import it.

---

### 8. The reconstruction seam

To call a persistent operation the wrapper needs a Value for its raw
`inner_header`. Each collection module owns that step:
`champ.valueFromMapHeader`, `champ.valueFromSetHeader` (which infer the
array-map or CHAMP subkind from the body) and
`vector.valueFromVectorHeader`. The transient module calls only these
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
- **Metadata**: `with-meta` is `:no-metadata-on-immediate`; `meta` is
  nil (SEMANTICS §7).

---

### 10. GC

`trace` marks `inner_header`, the wrapper's only outgoing reference,
whether the wrapper is active or frozen (`docs/GC.md` §5). A wrapper
that is the sole holder of its collection keeps it alive.

---

### 12. Testing

`test/prop/transient.zig`: T1a-T1d equivalence (random edit sequences
through a transient and through the persistent operations give `=` and
hash-equal results, for maps, sets and vectors, T1d with random
`conj!`/`assoc!`/`pop!`); T2a-T2d ownership (a frozen wrapper rejects
every operation; the wrong family gives `TransientKindMismatch`);
T3a-T3b the source collection is unchanged; T4, T4b the inner root
survives collection through an active or a frozen wrapper. These are
the transient properties of PLAN §20.2. Inline tests in
`transient.zig` cover the wrapper; `test/integration/eval_pipeline.zig`
("transients") covers the language surface.
