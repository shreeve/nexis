## TYPED_VECTOR.md — Typed Vector Heap Kind

The contract for the `typed_vector` heap kind
(`src/coll/typed_vector.zig`) and the natives over it
(`src/stdlib.zig`). Kind number and subkinds:
`docs/VALUE.md` §2.2. Header bits: `docs/HEAP.md`. Equality category
and hash domain: `docs/SEMANTICS.md` §3.3. Serializable and wire
format: `docs/CODEC.md` §2, §3.

A typed vector is an immutable, contiguous, unboxed sequence of one
numeric element type: one heap block, eight bytes per element, no
per-element `Value` tag, no trie. It is a separate kind from the
persistent vector; conversion is explicit (`i64-vector` / `f64-vector`
one way, `vec` the other).

---

### 1. Scope

The module provides construction from a Zig slice (`fromI64Slice`,
`fromF64Slice`, both copying their argument), `count`, `elemType`, the
element slices for kernels (`i64Elems`, `f64Elems`), `nth` (the element
as a Value), the element conversions `i64FromValue` / `f64FromValue`
the constructors use, `hashHeader`, `equalHeaders`, `trace` and
`format`. The language surface is §7.

**Absent.**

- `u8` elements: that is `Kind.byte_vector` (22), which has no
  implementation. `i32` and `f32`: subkinds 0 and 2 are reserved;
  `ElemType.fromTag` rejects their tags and the codec reports them as
  `MalformedPayload`.
- Any update operation: `conj`, `assoc`, `pop`, `peek`, `subvec` and
  `empty` are `:kind-mismatch`. A derived vector is a fresh allocation
  from a constructor or a `nexis.simd` kernel.
- Reader syntax. `#i64[1 2 3]` is how a typed vector prints; the
  reader has no `#i64[` / `#f64[` dispatch and the text is a parse
  error.
- Metadata: `with-meta` is `:kind-mismatch`, `meta` is nil
  (SEMANTICS §7).
- Metal or other off-CPU dispatch, the `simd` opcode group
  (`UnimplementedOpcode`, VM.md §10), and a shared representation with
  Nextomic's `Relation` columns, which are arena-scoped and never VM
  values.

---

### 2. Layout

The body is a 16-byte prefix, `len: u64` at 0, `elem: u8` at 8 and 7
bytes of padding, followed by `len × 8` bytes of elements at body
offset 16. The Value's subkind is the element type tag, the number
stored in `elem`:

| subkind / tag | element | status |
|---|---|---|
| 0 | `i32` | reserved |
| 1 | `i64` | two's-complement `i64` |
| 2 | `f32` | reserved |
| 3 | `f64` | IEEE 754 `f64`, canonical NaN |

**Invariants** (every live typed vector satisfies all):

1. `Heap.bodyBytes(h).len == 16 + len * 8`; the body starts 16-byte
   aligned (HEAP.md §1), so the elements are 8-byte aligned.
2. `elem` is 1 or 3 and equals the Value's subkind.
3. An `f64` element is canonical: every NaN written at construction or
   decode is `hash.canonical_nan_bits`. `-0.0` is stored as is.
4. The block has no heap references: `trace` is a no-op (GC.md §5).
5. The block is never mutated after construction.

---

### 3. Equality and hash

A typed vector is `=` only to another typed vector (SEMANTICS §3.3): it
is not sequential, so `(= (i64-vector [1 2]) [1 2])` is false, and the
element type is part of the value, so `(= (i64-vector [1 2])
(f64-vector [1 2]))` is false. `equalHeaders` requires the same element
type, the same length and every element pair equal: `i64` elements as
integers, `f64` elements as float Values compare (`-0.0` equals `+0.0`,
the canonical NaN equals itself; SEMANTICS §2.2).

`hashHeader` is an ordered combine (`ordered_init`, `combineOrdered`,
`finalizeOrdered` over the length) of the element type tag and then
every element, `hashI64` for `i64` and `hashFloat` (which folds signed
zero) for `f64`, truncated to `u32` and cached in the header when
nonzero (the HEAP.md cache rule). `dispatch.hashValue` mixes the kind's
domain in on top.

---

### 4. Codec

A typed vector is serializable; its encoding is the `typed_vector`
row of CODEC.md §2. Encode writes each `f64` element's canonical bits
and decode passes the elements through `fromF64Slice`, which
re-canonicalizes NaN. Every element is fixed-width in a fixed order,
so re-encoding a decoded typed vector is byte-equal (CODEC.md §4).
`db/put!`, `db/get`, `db/put-key!`, `db/get-key` and `@ref` carry typed
vectors through this encoding unchanged.

---

### 6. Printing

`src/format.zig` prints `#i64[1 -2 3]` and `#f64[1.0 2.5E7]` in both
the display and the readable mode: spaces between elements, no commas,
and each `f64` element exactly as the float Value `nth` returns for it
prints (SEMANTICS §6.3), `##NaN`, `##Inf` and `##-Inf` included.
The text does not read back (§1).

---

### 7. Natives

#### 7.1 `nexis.core`

| native | result | errors |
|---|---|---|
| `(i64-vector coll)` | an `i64` typed vector of the elements of `coll`, any seqable (nil is empty) | a non-integer element, a bignum outside `i64`, or a non-seqable `coll` is `:kind-mismatch` |
| `(f64-vector coll)` | an `f64` typed vector; a fixnum or bignum element widens to its nearest `f64` | a non-number element is `:kind-mismatch` |
| `(typed-vector? x)` | true for a typed vector of either element type | |
| `(typed-vector-type tv)` | `:i64` or `:f64` | a non-typed-vector is `:kind-mismatch` |

A typed vector is a seqable receiver wherever `makeSeqIter` is the
entry point, so the generic natives work on it: `seq`, `first`,
`rest`, `next`, `vec`, `reduce`, `into`, `map`, `filter`, `apply`,
`sort`, `some`, `every?`, `doseq`, destructuring. An element comes out
as a fixnum, a bignum when an `i64` is beyond the fixnum range, or a
float. The natives with their own kind switch:

| native | behaviour |
|---|---|
| `(count tv)` | the length |
| `(nth tv i)`, `(nth tv i default)` | the element; out of range is `:index-out-of-bounds`, or `default` |
| `(get tv i)`, `(get tv i default)` | the element, or `default` (nil) for a non-fixnum or out-of-range key |
| `(contains? tv i)` | true for a fixnum index within `0..count` |
| `(empty? tv)` | `(zero? (count tv))` |

A typed vector is not callable (`(tv 0)` is `:not-callable`), and
`coll?`, `sequential?` and `vector?` are false for it, as for a
primitive array in Clojure.

#### 7.2 `nexis.simd`

The kernels are the `nexis.simd` namespace, installed at VM startup
beside `nexis.core`; `(require '[nexis.simd :as tv])` aliases it
without loading a file. Each takes typed vectors; any other argument
in a typed-vector position is `:kind-mismatch`.

| native | result | errors |
|---|---|---|
| `(tv/sum xs)` | the sum: for `i64` the exact integer `(reduce + xs)` yields (a fixnum, or a bignum), for `f64` a float; `0` / `0.0` when empty | |
| `(tv/dot xs ys)` | the dot product, of the same result kind as `sum` and exact at any size for `i64` | element types differ: `:kind-mismatch`; lengths differ: `:invalid-argument` |
| `(tv/scale xs k)` | a typed vector of the same element type with every element multiplied by `k` | for `i64`, `k` must be an integer within `i64` (`:kind-mismatch`) and each product must fit `i64` (`:arithmetic-overflow`: an `i64` vector has no wider element to promote to); for `f64`, `k` is any number, widened |
| `(tv/map f xs)` | a typed vector of the input's element type whose elements are `(f x)`, `x` as `nth` returns it | a result that does not fit the element type under the §7.1 constructor rule is `:kind-mismatch` |

A function that maps to another kind is used with `map` or `mapv`.

The `f64` kernels run four lanes of `@Vector(4, f64)` and fold the
lanes at the end, so the association order differs from a left fold
and the low bits of a sum can differ from `(reduce + xs)`. The `i64`
kernels are scalar and exact: `sum` accumulates in `i128`, which no
vector that fits in memory can overflow; `dot` forms each product in
`i128` and spills the running total into a bignum when it leaves
`i128`; both hand the total to `bignum.fromI128`, so the result is a
fixnum or a bignum by value alone (SEMANTICS §2.2). `tv/map` calls `f`
through `vm.callValue`; the only heap Value it holds across those calls
is `xs`, rooted by the caller's argument slot (GC.md §11.5), and the
results are collected into a Zig-owned slice before the result vector
is allocated.

---

### 8. Errors

| keyword | raised by |
|---|---|
| `:kind-mismatch` | a constructor element of the wrong kind; a non-typed-vector to `typed-vector-type` or a kernel; an update native (`conj`, `assoc`, `pop`, `peek`, `subvec`, `empty`); `with-meta`; mismatched element types in `tv/dot`; a `tv/scale` or `tv/map` value that does not fit the element type |
| `:index-out-of-bounds` | `nth` without a default, index outside `0..count` |
| `:invalid-argument` | `tv/dot` over different lengths |
| `:arithmetic-overflow` | a `tv/scale` product outside `i64` on an `i64` vector |
| `:not-callable` | a typed vector in function position |

---

### 9. Testing

Inline tests in `src/coll/typed_vector.zig` cover layout and alignment,
construction, NaN canonicalization, `nth` (fixnum, bignum promotion,
float, out of bounds), equality and hash (signed zero and NaN
included), `format`, `ElemType.fromTag` and the no-op trace.
`test/prop/typed_vector.zig`: T1 codec round trip of both element types
at lengths 0, 1, 31, 32, 33 and 1000 (equality, hash, bit-exact
elements, byte-stable re-encode); T2 equality and hash agreement and
the three ways `=` breaks; T2b signed zero and NaN; T3 never `=` to a persistent vector; T4
`nth` over every index and `IndexOutOfBounds` at `count` and beyond.
`src/codec.zig` covers the byte layout, `MalformedPayload` on an
unknown element tag and `TruncatedInput` on an oversized count.
`test/integration/eval_pipeline.zig` (`typed vectors: ...`) covers the
language surface, the kernels and a store round trip, and
`examples/typed-vectors.nx` runs under `zig build examples`.
