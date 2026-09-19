## TYPED_VECTOR.md — Typed Vector Heap Kind

Authoritative body-layout, semantic and API contract for the
`typed_vector` heap kind (`src/coll/typed_vector.zig`) and the natives
over it (`src/stdlib.zig`). Derivative from `PLAN.md` §9.5, §15.10 and
§23 #25, `docs/VALUE.md` §2.2, `docs/SEMANTICS.md` §2.6 / §3.2,
`docs/CODEC.md`, `docs/GC.md` and `docs/HEAP.md`. Those documents win
on conflict.

A typed vector is an immutable, contiguous, unboxed sequence of one
numeric element type. It is the representation for bulk numeric data:
one heap block, eight bytes per element, no per-element `Value` tag,
no trie. It is a separate kind from the persistent vector; conversion
between the two is explicit (`i64-vector` / `f64-vector` one way,
`vec` the other).

---

### 1. Scope

**In:**

- Element types `i64` and `f64`. The element type is carried in the
  Value's subkind and in the body (§2).
- Construction from a Zig slice (`fromI64Slice`, `fromF64Slice`) and,
  at the language level, from any seqable of numbers (`i64-vector`,
  `f64-vector`).
- Accessors: `count`, `nth` (a fixnum, a bignum beyond the fixnum
  range, or a float), the element slices for kernels.
- Structural equality and hash (§3), codec arms (§4), a leaf `trace`
  (§5), printing (§6), the `nexis.core` and `nexis.simd` natives (§7).

**Absent, explicitly:**

- `u8` elements: that is `Kind.byte_vector` (22), which has no
  implementation. `i32` and `f32`: the subkinds 0 and 2 VALUE.md §2.2
  reserves for them have no implementation; `ElemType.fromTag` rejects
  their tags and the codec reports them as `MalformedPayload`.
- Any update operation. There is no `conj`, `assoc`, `pop` or `subvec`
  over a typed vector; each throws `:kind-mismatch` from the generic
  native. A derived vector is a fresh allocation from a
  constructor or a `nexis.simd` kernel.
- Reader syntax. `#i64[1 2 3]` is how a typed vector prints; the
  reader has no `#i64[` / `#f64[` dispatch and rejects the text with a
  parse error at the `#`.
- Metadata: `with-meta` on a typed vector is `:no-metadata-on-immediate`
  (SEMANTICS §7).
- A cached hash: `hashHeader` walks the elements on every call.
- Metal or other off-CPU dispatch (PLAN §19.5).

---

### 2. Layout

```
HeapHeader                 kind = 23 (typed_vector)
Body (16 bytes)            len: u64 at 0; elem: u8 at 8; 7 bytes of padding
elements (len × 8 bytes)   at body offset 16, 8-byte aligned
```

The Value's subkind is the element type tag, the same number stored
in `Body.elem`:

| subkind / tag | element | status |
|---|---|---|
| 0 | `i32` | reserved, no implementation |
| 1 | `i64` | two's-complement `i64` |
| 2 | `f32` | reserved, no implementation |
| 3 | `f64` | IEEE 754 `f64`, canonical NaN |

**Frozen invariants** (every live typed vector satisfies all):

1. `Heap.bodyBytes(h).len == 16 + len * 8`; the body starts 16-byte
   aligned (HEAP.md §1), so the elements are 8-byte aligned.
2. `Body.elem` is 1 or 3 and equals the Value's subkind.
3. An `f64` element is canonical: every NaN written at construction or
   decode is `hash.canonical_nan_bits`. `-0.0` is stored as is.
4. The block has no heap references: it is a GC leaf (§5).
5. The block is never mutated after construction.

`fromI64Slice` and `fromF64Slice` copy their argument; the caller's
slice is not retained.

---

### 3. Equality and hash

Typed vectors are **kind-local** (`dispatch.eqCategory(.typed_vector)
== .kind_local`, domain byte 23), as SEMANTICS §2.6 pins: they are
not in the sequential category. Consequences:

- `(= (i64-vector [1 2]) [1 2])` is `false`, as is
  `(= (i64-vector [1 2]) '(1 2))`; `dispatch.equal` answers from the
  category rule before any per-kind routine runs.
- `(= (i64-vector [1 2]) (f64-vector [1.0 2.0]))` is `false`: the
  element type is part of the value.
- Two typed vectors are `=` iff they have the same element type, the
  same length, and every element pair is equal. `i64` elements compare
  as integers; `f64` elements compare as float Values do — `-0.0`
  equals `+0.0` and the canonical NaN equals itself (SEMANTICS §2.2).

The hash is an ordered combine (`hash.ordered_init`,
`hash.combineOrdered`, `hash.finalizeOrdered` over the length) of the
element type tag followed by every element, `hash.hashI64` for `i64`
and `hash.hashFloat` for `f64` (which folds signed zero), so
`(= a b) ⇒ (= (hash a) (hash b))` holds by construction.
`dispatch.hashValue` applies `mixKindDomain(base, 23)` on top.

---

### 4. Codec

A typed vector is a serializable kind (PLAN §15.10, §23 #25). The
kind byte is its tag, as for every other kind (CODEC.md §2):

```
[23] [elem: u8 ∈ {1, 3}] [unsigned LEB128 count] [u64 LE × count]
```

`i64` elements are their two's-complement bits; `f64` elements their
IEEE bits, canonicalized on the way out. Decode rejects any other
`elem` byte with `MalformedPayload` and checks that `count × 8` bytes
remain before allocating anything, so a corrupt count is
`TruncatedInput` rather than a huge scratch buffer. Every decoded
`f64` goes through `fromF64Slice`, which re-canonicalizes NaN. The
element order is fixed and every element is fixed-width, so a typed
vector is a canonical-order kind: `encode(decode(encode(v)))` is
byte-equal to `encode(v)` (CODEC.md §4).

`db/put-key!` / `db/get-key`, `db/put!` / `db/get` and `@ref` carry
typed vectors through this encoding unchanged.

---

### 5. GC trace

`typed_vector.trace` is a no-op: the body is unboxed numbers with no
heap references (GC.md §5 rule 5). The collector's kind switch
dispatches `.typed_vector` to it, apart from the "panic (unallocated)"
group of kinds that have no implementation.

---

### 6. Printing

`src/format.zig` prints `#i64[1 -2 3]` and `#f64[1.0 2.5E7]` in both
the display and the readable mode, spaces between elements, no
commas. An `f64` element prints exactly as the float Value `nth`
returns for it (SEMANTICS §6.3): mandatory fraction, exponent form
at or above `1e7` and below `1e-3`, `NaN`, `Infinity`, `-Infinity`.
The text does not read back (§1).

---

### 7. Natives

#### 7.1 `nexis.core`

| native | result | errors |
|---|---|---|
| `(i64-vector coll)` | an `i64` typed vector of the elements of `coll`, any seqable (nil is empty) | a non-integer element, or a bignum outside `i64`, is `:kind-mismatch`; a non-seqable `coll` is `:kind-mismatch` |
| `(f64-vector coll)` | an `f64` typed vector; a fixnum or bignum element widens to its nearest `f64`, a float is stored as is | a non-number element is `:kind-mismatch` |
| `(typed-vector? x)` | `true` for a typed vector of either element type | — |
| `(typed-vector-type tv)` | `:i64` or `:f64` | a non-typed-vector is `:kind-mismatch` |

A typed vector is a seqable receiver everywhere `makeSeqIter` is the
entry point, so the generic natives work on it without a special
case: `seq`, `first`, `rest`, `next`, `vec` (a persistent vector of
the elements), `reduce`, `into` (from a typed vector into any
collection), `map`, `filter`, `apply`, `sort`, `some`, `every?`,
`doseq`, destructuring. Elements come out as Values: an `i64`
element as a fixnum, or as a bignum when it is beyond the fixnum
range; an `f64` element as a float. The natives with their own kind
switch have an arm:

| native | behaviour |
|---|---|
| `(count tv)` | the length |
| `(nth tv i)`, `(nth tv i default)` | the element; out of range is `:index-out-of-bounds`, or `default` |
| `(get tv i)`, `(get tv i default)` | the element, or `default` (nil) for a non-fixnum or out-of-range key |
| `(contains? tv i)` | `true` for a fixnum index within `0..count`, as for a persistent vector |
| `(empty? tv)` | `(zero? (count tv))` |
| `(= a b)`, `(hash tv)`, `(identical? a b)` | §3 |
| `(str tv)`, `(pr-str tv)`, `(println tv)` | §6 |

What does not work, and why: `conj`, `assoc`, `pop`, `peek`,
`subvec` and `empty` are `:kind-mismatch` (a typed vector
has no update operation, §1); a typed vector is not callable (`(tv 0)`
is `:not-callable`, the lookup-callable kinds are keywords, maps, sets
and persistent vectors); `coll?`, `sequential?` and `vector?` are
`false`, as they are for a primitive array in Clojure; `with-meta` is
`:no-metadata-on-immediate`.

#### 7.2 `nexis.simd`

The kernels live in the `nexis.simd` namespace, installed at VM
startup beside `nexis.core` (a `require` of it aliases without loading
a file, like `db` and `nextomic`). Every example and test writes
`(require '[nexis.simd :as tv])`.

| native | result | errors |
|---|---|---|
| `(tv/sum xs)` | the sum of the elements: the exact integer for `i64` (a fixnum, or a bignum beyond the fixnum range, the value `(reduce + xs)` yields), a float for `f64`; `0` / `0.0` when empty | — |
| `(tv/dot xs ys)` | the dot product, of the same result kind as `sum` and exact at any size for `i64` | element types differ: `:kind-mismatch`; lengths differ: `:invalid-argument` |
| `(tv/scale xs k)` | a typed vector of the same element type with every element multiplied by `k` | for `i64`, `k` must be an integer within `i64` (`:kind-mismatch`) and each product must fit `i64` (`:arithmetic-overflow`: the result is an `i64` vector, so a product outside `i64` has no representation); for `f64`, `k` is any number, widened |
| `(tv/map f xs)` | a typed vector of the same element type whose elements are `(f x)` for each element `x` (passed as the Value `nth` returns) | each result must fit the element type under the constructor rule of §7.1: an integer within `i64` for an `i64` vector, any number for an `f64` vector; otherwise `:kind-mismatch` |

`tv/map` always returns a typed vector of the input's element type;
a function that maps to another kind is used with `map` or `mapv`
instead, which work on a typed vector as on any seqable.

The `f64` kernels run four lanes of `@Vector(4, f64)` and fold the
lanes at the end, so the association order differs from a left fold
and the low bits of a sum can differ from `(reduce + xs)`. The `i64`
kernels are scalar and exact: `sum` accumulates in `i128`, which the
elements of any vector that fits in memory cannot overflow; `dot`
forms each product in `i128` and, when the running total leaves
`i128`, spills it into a bignum and continues; each hands its total
to `bignum.fromI128`, so the result is a fixnum or a bignum by value
alone, as `(reduce + xs)` promotes (SEMANTICS.md §2.2). `scale` is
the one kernel, and the one arithmetic in the language, that raises
`:arithmetic-overflow`: its result is an element-typed `i64` vector
with no wider element to promote to. `tv/map` calls the
function once per element through `vm.callValue`; the only heap Value
it holds across those calls is `xs`, which the caller's argument slot
keeps reachable (GC.md §11.5), and the results are collected into a
Zig-owned slice before the result vector is allocated.

---

### 8. Errors

| keyword | raised by |
|---|---|
| `:kind-mismatch` | a constructor element of the wrong kind; a non-typed-vector to `typed-vector-type`; an update native (`conj`, `assoc`, ...); mismatched element types in `tv/dot`; a `tv/scale` or `tv/map` value that does not fit the element type |
| `:index-out-of-bounds` | `nth` without a default, index outside `0..count` |
| `:invalid-argument` | `tv/dot` over different lengths |
| `:arithmetic-overflow` | a `tv/scale` product outside `i64` on an `i64` vector |
| `:not-callable` | a typed vector in function position |
| `:no-metadata-on-immediate` | `with-meta` |

---

### 9. Testing

Inline tests in `src/coll/typed_vector.zig`: layout and alignment,
construction of both types, NaN canonicalization, empty vectors,
`nth` (fixnum, bignum promotion, float, out of bounds), equality and
hash (across allocations; type, length and element differences;
signed zero and NaN), `format`, `ElemType.fromTag`, the no-op trace.

`test/prop/typed_vector.zig`: T1 codec round trip for both element
types at lengths 0, 1, 31, 32, 33 and 1000 (equality, hash,
bit-exact elements, byte-stable re-encode); T2 equality/hash
agreement and the three ways `=` breaks; T3 never `=` to a persistent
vector; T4 `nth` over every index and `IndexOutOfBounds` at `count`
and beyond.

`src/codec.zig`: round trip of both types with the extremes, the
byte layout of one encoding, `MalformedPayload` on an unknown element
tag, `TruncatedInput` on an oversized count with no allocation.

`test/integration/eval_pipeline.zig` (`typed vectors: ...`): the
constructors and their errors, the generic natives, printing, the
`nexis.simd` kernels, the update natives' `:kind-mismatch`, and a
`db/put-key!` / `db/get-key` round trip through a store.

`examples/typed-vectors.nx` runs under `zig build examples`.

---

### 10. What TYPED_VECTOR.md does not cover

- **Nextomic's `Relation`** (`src/nextomic/relation.zig`). Its
  columns are arena-scoped, widen from `int` to `cell` on the first
  non-integer value, and are never VM values; they do not share this
  representation (PLAN §15.11 NX-2 names typed vectors as the intended
  backing; the built Relation keeps its own columns).
- **The `simd` ISA group** (VM.md §10). The kernels are natives; the
  opcode group stays `UnimplementedOpcode`.
- **`byte_vector`** (kind 22): no implementation.
