## SEMANTICS.md — Value-Layer Semantics for nexis

Freezes the numeric corner cases, truthiness, equality, hashing,
nil-propagation, interning, and print/read contract that `value.zig`,
`hash.zig` and `dispatch.zig` implement. Derivative from `PLAN.md` §6 and §8.
PLAN.md wins on any apparent conflict.

Risk-register entry #13 (PLAN §25) is this document: "Numeric corner cases
poison eq/hash/codec" — mitigated by pinning every edge case here.

---

### 1. Truthiness (frozen)

Only `nil` and `false` are **falsy**. Everything else is truthy, including:

- `0`, `0.0`, `-0.0`, `+inf`, `-inf`, `+nan`
- `""` (empty string), `[]`, `{}`, `#{}`, `()` (empty collections)
- `\space`, `\null`-equivalents, any char

This is PLAN §23 decision 13. It is non-negotiable and determines the feel of
every conditional in the language.

---

### 2. Equality (`=`) — frozen semantics

Two levels (PLAN §6.3):

- `(identical? x y)` — pointer/identity. Used rarely.
- `(= x y)` — value equality. Specified per kind below.

**Cross-kind rule.** Unless a category rule below says otherwise, values of
different kinds compare `false` under `=`. No implicit numeric coercion, no
collection↔string coercion, no keyword↔symbol coercion.

#### 2.1 Nil and booleans

- `(= nil nil)` → `true`.
- `(= nil false)` → `false`. Nil is not false.
- `(= true true)` → `true`; `(= true 1)` → `false` (no truthy-coercion).

#### 2.2 Numbers

**Cross-type is always false in v1** (PLAN §23 decision 11):

- `(= 1 1.0)` → `false`.
- `(= 1 (bignum 1))` — this specific call is not observable because of
  the canonicalization invariant below: constructing a bignum whose
  magnitude fits in the fixnum range returns a `fixnum`, not a bignum.
  Phrased as an invariant: **for integers, the runtime guarantees
  that two mathematically-equal integers are always represented by
  exactly one runtime kind/value form in v1.** Equality and hash are
  consistent across the fixnum↔bignum boundary *by construction*, not
  by a cross-kind rule.

**Fixnum range is i48**, inclusive on both ends:

- `min = -(2⁴⁷) = -140_737_488_355_328`
- `max =  2⁴⁷ - 1 = 140_737_488_355_327`
- Canonicalization must fold any integer in `[min, max]` to `fixnum`.
  The asymmetric lower bound is deliberate: it matches the
  authoritative `src/value.zig` constants
  `fixnum_min` / `fixnum_max` and the standard signed-i48
  two's-complement range. Bignum construction that sees a magnitude
  equal to `2⁴⁷` with negative sign must canonicalize to
  `fixnum(-2⁴⁷)`, not a bignum.

Integer tower (`fixnum` + `bignum`):

- Arithmetic that overflows a fixnum promotes to bignum. Arithmetic
  that would underflow into fixnum range canonicalizes back to fixnum.
  Equality and hash are consistent across this boundary by construction.
- `(= 0 -0)` → `true`. There is no signed zero in the integer tower.
  Canonicalization must treat any zero magnitude as `fixnum(0)`
  regardless of sign input; a "negative zero bignum" is unrepresentable.

Float (`f64`):

- **Negative zero.** `(= 0.0 -0.0)` → `true`. Equality uses IEEE numerical
  equality *except* as specified for NaN below. `(identical? 0.0 -0.0)` is
  `false`.
- **Canonical NaN.** The runtime stores NaN as a single canonical bit pattern
  (the quiet NaN with zero payload: `0x7FF8000000000000`). Any incoming NaN
  is canonicalized on entry to the Value layer. Therefore `(= nan nan)`
  **returns `true`**, diverging from IEEE 754's "NaN ≠ NaN" semantics. This is
  a deliberate choice: Clojure treats NaN as non-`=` to anything (inherited
  from JVM `Double.equals`) which breaks the reflexivity of `=` and
  correspondingly the soundness of map lookup where NaN is a key. We choose
  reflexive equality + canonical bit pattern so that:
  - `=` is an equivalence relation on every Value.
  - `(assoc m nan v)` then `(get m nan)` returns `v`.
  - `hash` can be defined as `hash(canonical-nan) = <fixed constant>` and the
    `(= a b) ⇒ (= (hash a) (hash b))` invariant holds trivially.
  Math operations still propagate NaN per IEEE; only `=` is canonical.
- `(= +inf +inf)` → `true`; `(= -inf -inf)` → `true`; `(= +inf -inf)` →
  `false`.
- Float subnormals compare numerically; no flush-to-zero.

Cross-type operators (PLAN §8.3):

- Arithmetic and ordered comparison follow Clojure contagion: an
  operation with any float operand is carried out in f64 and yields a
  float; integers stay integral and exact. `(< 1 1.5)` → `true`,
  `(+ 1 0.5)` → `1.5`, `(max 1 2.0)` → `2.0`. A bignum operand widens
  to the nearest f64 (`(== (* 2 140737488355327) 2.81474976710654E14)`
  → `true`).
- `==` is numeric equality under contagion: `(== 1 1.0)` → `true` while
  `(= 1 1.0)` stays `false` (PLAN §23 decision 11). `==` is IEEE on NaN:
  `(== nan nan)` → `false` even though `(= nan nan)` → `true`.
- `/` on two fixnums yields a fixnum when the division is exact and a
  float otherwise: `(/ 6 3)` → `2`, `(/ 7 2)` → `3.5`. There are no
  rationals (PLAN §23 decision 10).
- An integer result outside the i48 range is a bignum, exact at any
  size: `(+ 140737488355327 1)` → `140737488355328`, `(* 100000000
  10000000000)` → `1000000000000000000`. An integer result that fits
  is a fixnum whatever its operands were, so `(- (+ 140737488355327 1)
  1)` is the fixnum `140737488355327` again. `quot`, `rem`, `mod`, `abs`
  and unary `-` promote the same way (`(- -140737488355328)` →
  `140737488355328`). Ordering, `compare`, `max`, `min`, `zero?`,
  `pos?`, `neg?`, `even?` and `odd?` are exact over bignums. No
  arithmetic raises `:arithmetic-overflow`, with one exception: the
  element-typed kernel `tv/scale` over an `i64` typed vector, whose
  result is an `i64` vector with no wider element to promote to
  (TYPED_VECTOR.md §7.2). `tv/sum` and `tv/dot` are exact and
  promote like `(reduce + xs)`.
- `zero?`, `pos?` and `neg?` are all `false` on NaN, which is neither
  zero, positive nor negative (Clojure's `isZero`, `isPos` and `isNeg`
  agree); `-0.0` is zero. The infinities are positive and negative.
- Integer `/` by zero, and `quot` / `rem` / `mod` by zero of any kind,
  raise `:divide-by-zero`. Float `/` by zero is IEEE: `Infinity`,
  `-Infinity` or `NaN`.
- `even?` / `odd?` accept integers only (`:kind-mismatch` on a float).
- `(long x)` is `x` for an integer and the integer part of a finite
  float (toward zero, a bignum when wide: `(long 1e30)` →
  `1000000000000000019884624838656`); NaN and the infinities raise
  `:invalid-argument`. `(double x)` is the nearest f64 of any number.
  The integer tower has one type, so `long` never rejects a size.

#### 2.3 Characters

- `(= \a \a)` → `true`; character equality is Unicode scalar value equality.
- `(= \a "a")` → `false`. Chars are not length-1 strings.

#### 2.4 Strings

- Byte-for-byte comparison after UTF-8 normalization. v1 does **not** perform
  Unicode NFC/NFD normalization; `(= "é" "é")` depends on source byte content
  (precomposed vs combining). This is intentional — automatic normalization
  costs performance and surprises people editing raw bytes. Users who need
  canonical comparison can call `string/normalize` (v2+).
- Empty string equals only empty string.
- `(= "" nil)` → `false`.

#### 2.5 Keywords and symbols

- `(= :foo :foo)` → `true`. Keyword equality is intern-id identity after
  auto-interning — cheap.
- `(= :foo :ns/foo)` → `false`. Namespaced and unqualified keywords are
  different identities.
- `(= 'foo 'foo)` → `true` for plain interned symbols.
- `(= 'foo :foo)` → `false`. Keyword and symbol live in **different hash
  domains** (PLAN §8.4) so they never collide in maps.
- Symbols carry no metadata (§7): `(with-meta 'foo {:a 1})` throws
  `:no-metadata-on-immediate`.

#### 2.6 Collections, and the three rules of `=` (PLAN §6.6, §23 decision 36)

`src/dispatch.zig` decides every pair of values by one of three rules:

| Rule | Kinds | `=` | `hash` |
|---|---|---|---|
| **sequential** | `list`, `vector` | element-wise, across the two kinds | ordered combine, one shared domain byte `0xF0` |
| **identity** | function, native fn, var, the db handles, transient, atom, protocol, protocol fn, Nextomic connection | the same value only | the pointer (the collector never moves a block) |
| **kind-local** | every other kind | within the kind only, by the kind's structural rule | the kind's own hash, domain byte = the kind byte |

Worked examples:

- `(= (list 1 2 3) [1 2 3])` → `true`, and the hashes agree.
- `(= [1 2 3] #{1 2 3})` → `false`.
- `(= {:a 1} [:a 1])` → `false`.
- `(= () nil)` → `false` (nil is not a sequential; empty-list is).
- `(= (list) [])` → `true` (both empty sequentials).
- `(= (map inc [1 2 3]) [2 3 4])` → `true` (map returns sequential).

Maps compare entry-wise across their two layouts (array-map and CHAMP
are subkinds of one kind); sets likewise. A record is equal to a record
of the same type with equal fields (`docs/PROTOCOLS.md` §2.1), never to
its field map.

Typed vectors (`i64-vector`, `f64-vector`) are **not** in the
sequential category. They are their own kind with element-wise
equality, same element type required: `(= (i64-vector [1 2]) [1 2])` →
`false`, `(= (i64-vector [1 2]) (f64-vector [1.0 2.0]))` → `false`
(`docs/TYPED_VECTOR.md` §3).

Durable refs (`durable-ref`) compare by identity triple
`{store-id, tree-id, key-bytes}`, never by dereferenced value (PLAN §8.6,
§15.2). A Nextomic db-value compares by connection, basis and mode; an
entity by its db-value and eid.

Identity kinds: two atoms holding `(= a b)` values are still
`(not (= atom-a atom-b))`, and an atom's hash does not change when its
value does. This matches Clojure and is load-bearing: a mutable value
that took part in structural equality would let a map key become
unequal to itself on mutation. A transient hashes by identity as in
Clojure, so it may be a map key; it compares equal to no persistent
collection.

#### 2.7 Values nested deeper than the native stack

`=`, `hash` and printing recurse on nesting depth on the native stack.
Past the stack guard (`src/stack.zig`) they do not fault: the step that
ran out answers `false`, `0` or a `#<too deep>` marker and counts an overflow (`dispatch.overflowCount`), and the VM turns a
count that changed across a native call or opcode into the catchable
`:stack-overflow` (`docs/VM.md` §13.1). A map, set or record whose hash
was computed past an overflow keeps no cached hash, so the wrong answer
never outlives the throw. The codec bounds nesting at a fixed 4096
levels instead (`docs/CODEC.md` §2.7).

---

### 3. Hashing — invariants

The bedrock invariant (PLAN §6.3):

> `(= x y) ⇒ (= (hash x) (hash y))`

Non-negotiable. `test/prop/codec.zig` exercises this on randomized
values.

#### 3.1 Scope and stability

- Hash is stable **within a process** only. No hash is persisted: the
  codec writes values, never hashes, and a decoded collection is
  rebuilt with the reading process's hashes. The seed and the domain
  bytes may change freely.
- Hashes are `u64`. String, bignum, map, set and record hashes are
  truncated to `u32` and cached in the HeapHeader `hash` slot, `0`
  meaning "uncomputed".
- Metadata never contributes to hash (PLAN §23 decision 12).

#### 3.2 Per-kind hash functions

Every hash is xxHash3-64 (seed: the bytes `"nexis1/1"`) of the kind's
discriminating bytes, then **domain-mixed**:
`hash = base + domain_byte * 0x9E3779B97F4A7C15`, where the domain byte
is the kind byte, or `0xF0` for list and vector (§2.6). The mixing keeps
kinds whose raw payload hashes coincide (`fixnum(65)`, `char(65)`,
`symbol(65)`, `keyword(65)`) apart, and subsumes Clojure's
keyword-only `^ 0x9E3779B9` offset.

- **`nil`** → base `0xB01DFACEB01DFACE`; **`false`** → `0`; **`true`**
  → `0x1111111111111111`.
- **`char`** → the scalar as 4 little-endian bytes.
- **`fixnum`** → the i64 as 8 little-endian bytes.
- **`bignum`** → the sign byte and the limbs. Fixnum-range bignums are
  impossible by construction (they canonicalize), so an equal fixnum
  and bignum never arise.
- **`float`** → the IEEE bits, with `-0.0` hashed as `+0.0` (so
  `(= 0.0 -0.0)` keeps hash equality) and NaN canonical
  (`0x7FF8000000000000`).
- **`string`** → the raw bytes.
- **`keyword`**, **`symbol`** → the intern id as 8 bytes; the two kinds
  differ by domain byte.
- **Sequential collections** — ordered combine:
  `h = 1; for each x: h = 31 * h + hash(x); finalize h with count`.
- **Maps** — unordered combine over per-entry ordered pairs:
  - Per-entry: `entry_h = 31 * (31 * 1 + hash(k)) + hash(v)`, two
    ordered combines with no finalize and no domain byte.
  - Aggregate: `h = 0; for each entry: h += entry_h; finalize h with
    count`. The ordered combine within an entry keeps the hash
    sensitive to a swapped key and value; the unordered combine across
    entries keeps it insensitive to entry order.
- **Sets** — unordered combine:
  `h = 0; for each x: h += hash(x); finalize h with count`.
- **`record`** → the type id and the field map's hash.
- **`typed-vector`** → the element type and the elements.
- **`durable-ref`** → `store-id ++ tree-id-bytes ++ key-bytes`; the
  dereferenced value is not consulted.
- **Identity kinds** (§2.6) → the pointer.

---

### 4. Nil propagation on collection ops (frozen)

Mirrors PLAN §6.5.

| Operation | On `nil` |
|---|---|
| `(count nil)` | `0` |
| `(seq nil)` | `nil` |
| `(get nil k)` | `nil` |
| `(get nil k default)` | `default` |
| `(first nil)` | `nil` |
| `(rest nil)` | `()` (empty list) |
| `(conj nil x)` | `(list x)` |
| `(assoc nil k v)` | `{k v}` (a new map) |
| `(keys nil)`, `(vals nil)` | `nil` (as for `(keys {})`: a map with no entries has no key seq) |
| `(flatten nil)` | `()` |
| `(select-keys nil ks)` | `{}` |

These determine the ergonomic feel of idiomatic nexis code and are frozen.

The seq of a vector is a view, not a copy: `seq`, `rest`, `next`,
`nthrest`, `nthnext` and `drop` of a vector take O(1) time and space
whatever its length (`docs/LIST.md` §1), so `(loop [v v] (when (seq v)
... (recur (pop v))))` is linear. The view is a list to everything
else: `seq?` is true, it prints as `(...)`, it is `=` to and hashes as
the list of the same elements, and the codec encodes it as a list.

Two further sequence rules follow Clojure exactly and are easy to
get backwards:

- `flatten` flattens lists and vectors only; nil elements are kept
  (`(flatten [1 nil [2]])` is `(1 nil 2)`), and a non-sequential
  argument — a number, a string, a map, nil — flattens to `()`.
- A negative count means zero in every counting function:
  `(nthrest xs -1)` is `xs`, `(split-at -1 xs)` is `[() xs]`,
  `(take-last -1 xs)`, `(repeat -1 x)` and `(repeatedly -1 f)` are
  `()`.

Records are maps to every collection function: `count`, `empty?`,
`not-empty`, `seq`, `keys`, `conj` and `into` see the field map,
`conj`/`into`/`assoc` return a record of the same type, and
`(empty r)` is `{}`.

---

### 5. Interning (PLAN §8.4)

- Keywords and symbols are interned; the interned id is what the Value
  payload carries. Neither carries metadata (§7).
- Intern ids are process-local. Serialization always emits textual form
  (PLAN §15.10) and the receiver re-interns.
- Keyword and symbol hashes live in different domains (§3.2), so `:foo`
  and `'foo` never collocate in one HAMT slot.

---

### 6. Print / read round-trip contract

For every value kind, a **pr-style** textual representation exists such that:

> `(read-string (pr-str v)) = v` under `=`, and
> `(hash (read-string (pr-str v))) = (hash v)`.

#### 6.1 Which kinds round-trip via print/read

- `nil`, `bool`, `char`, `fixnum`, `bignum`, `float` — yes.
- `string` — yes.
- `keyword`, `symbol` — yes (textual form; re-interned on read).
- `list`, `vector`, `map`, `set` — yes, recursively.
- `typed-vector` — no. It prints as `#i64[1 2 3]` / `#f64[1.0 2.0]`,
  which the reader rejects at the `#`; the codec is its round trip.
- `record` — no. It prints as `#ns.Type{:field value, ...}` in both
  modes, as Clojure does; the reader has no tagged literals.
- `durable-ref` — no. It prints as the opaque token
  `#<durable-ref :<tree> hex:<key-bytes>>`, which does not read back.

#### 6.2 Which kinds do **not** round-trip

- `function`/`closure`, `var`, `transient`, `atom`, protocols, the db
  and Nextomic handles. These print as `#<...>` markers (a var as
  `#'ns/name`) for debugging but do not parse back. Matches PLAN §15.10
  "not serializable".

#### 6.3 Numeric print rules

- Integers print in decimal, no leading zeros, with `-` for negatives,
  at any size and with no suffix: `(str (* 4294967296 4294967296))` is
  `"18446744073709551616"`, and reading that text back yields the same
  bignum. Hex/binary source literals do **not** round-trip: `(pr-str
  0x2A)` is `"42"`, and reading `"42"` back yields the same integer
  value.
- Floats print the way Clojure prints doubles: the shortest decimal that
  reads back to the same f64, always with a fraction (`1.0`, `2.5`,
  `100.0`), switching to exponent form with a one-digit integer part at
  or above `1e7` and below `1e-3` (`1.0E10`, `1.23456785E7`, `1.0E-4`).
  Specials:
  - `+inf` → `"Infinity"`; the reader has no `##Inf` literal, so it
    does not read back (`docs/FORMS.md` §8).
  - `-inf` → `"-Infinity"`; same caveat.
  - Canonical NaN → `"NaN"`; the reader has no `##NaN` literal.
- `0.0` prints as `"0.0"`, `-0.0` prints as `"-0.0"`. Both read back as
  their respective bit patterns; equality collapses them but identity does
  not.

#### 6.4 Character print rules

Named set: `\newline`, `\space`, `\tab`, `\return`, `\formfeed`,
`\backspace`. All other chars print as:
- single ASCII printable → `\a`
- anything else → `\u{HEX}` with uppercase hex digits, no leading zeros.

Reader accepts the same set (PLAN §7.2 / §23 decision 26).

#### 6.5 String print rules

Printed double-quoted. Escapes: `\n \t \r \\ \" \u{HEX}`. No multi-line
strings (PLAN §7.2 — source may not contain raw newlines inside a string).

---

### 7. Value attachability matrix for metadata

PLAN §8.5 is the target matrix; this is what the runtime does.

| Kind | `with-meta` | `meta` |
|---|---|---|
| `list`, `vector`, `map`, `set` | a copy of the root object carrying the map (`with-meta`, `vary-meta`); every node below the root is shared | the map or nil |
| `var` | `:no-metadata-on-immediate`; a Var's metadata changes in place with `reset-meta!` / `alter-meta!`, and `def`, `defn` and `defmacro` set it from `^meta` on the name, a docstring (`:doc`) and an attribute map, `defn` adding `:arglists` | the map or nil |
| `nil`, `bool`, `char`, `fixnum`, `bignum`, `float`, `keyword`, `string`, `durable-ref`, `transient`, the db and Nextomic handles | `:no-metadata-on-immediate` | nil |
| `symbol`, `function`, `record`, `byte-vector`, `typed-vector` | `:no-metadata-on-immediate`: PLAN §8.5 lists them attachable; no heap form for a symbol with metadata exists, and a closure block's `meta` field is never set | nil |

Metadata never takes part in `=`, `hash`, printing or the codec
(PLAN §23 #12): `(= v (with-meta v m))` is true and the two hash
alike. The metadata argument is a map or nil; anything else is
`:kind-mismatch`.

---

### 8. Deliberate non-decisions

These are explicitly **not** frozen yet; they are PLAN §24 open questions
and must not be silently decided in implementation:

- Laziness of `map`/`filter`/`reduce` (PLAN §24.2): v1 is eager, returning
  vectors.
- Schema/spec (PLAN §24.5): none.

If you need one of these, stop and amend PLAN.md first.
