## SEMANTICS.md — Value-Layer Semantics for nexis

**Status**: Phase 0 deliverable. Freezes the numeric corner cases, truthiness,
equality, hashing, nil-propagation, interning, and print/read contract **before
any Phase 1 eq/hash/GC code is written**. Derivative from `PLAN.md` §6 and §8.
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
  The asymmetric lower bound (one below the symmetric `±(2⁴⁷−1)`
  statement previous versions of this document carried) is
  deliberate: it matches the authoritative `src/value.zig` constants
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

Cross-type operators:

- `<`, `<=`, `>`, `>=` between numbers of mixed integer/float kinds throw
  `:type-error` in v1. The user must explicitly cast. Future `==` for
  cross-type numeric equality is deferred to v2 (PLAN §6.3 / §23 decision 11).

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
- Metadata on symbols is **ignored** for equality. `(= (with-meta 'foo {:a
  1}) 'foo)` → `true`. (PLAN §23 decision 12: metadata never affects
  equality or hash.)

#### 2.6 Collections — three-category rule (PLAN §6.6, §23 decision 36)

Equality partitions into three categories. Within a category, equality is
structural element-wise. Across categories, equality is always `false`.

| Category | Members |
|---|---|
| **sequential** | `list`, `vector`, lazy `seq`, cons cells |
| **map** | persistent-map, array-map |
| **set** | persistent-set |

Worked examples (copy-pasted from PLAN §6.6):

- `(= (list 1 2 3) [1 2 3])` → `true`.
- `(= [1 2 3] #{1 2 3})` → `false` (cross-category).
- `(= {:a 1} [:a 1])` → `false` (cross-category).
- `(= () nil)` → `false` (nil is not a sequential; empty-list is).
- `(= (list) [])` → `true` (both empty sequentials).
- `(= (map inc [1 2 3]) [2 3 4])` → `true` (map returns sequential).

Byte-vectors and typed-vectors (`int32-vector` etc.) are **not** in the
sequential category in v1. They are their own kinds with identity-free
equality (element-wise, same element type required). `(= (int32-vector [1
2]) [1 2])` → `false`. This preserves SIMD-friendly layouts without forcing a
structural-comparison path through generic sequence code.

Durable refs (`durable-ref`) compare by identity triple
`{store-id, tree-id, key-bytes}`, never by dereferenced value (PLAN §8.6,
§15.2).

Vars compare by identity (PLAN §13.3).

Functions, closures, transients: equality is identity-based; serialization
is disallowed (PLAN §15.10).

---

### 3. Hashing — invariants

The bedrock invariant (PLAN §6.3):

> `(= x y) ⇒ (= (hash x) (hash y))`

Non-negotiable. Phase 1 gate property test #5 exercises this on 100k+
randomized values.

#### 3.1 Scope and stability

- Hash is stable **within a process**. Across processes, stability is
  guaranteed only for values that round-trip through the codec (PLAN §6.3,
  §15.10).
- Hash is a `u32` stored cached on every heap object (HeapHeader `hash`, PLAN
  §8.2). A sentinel value `0` means "uncomputed".
- Metadata never contributes to hash (PLAN §23 decision 12).

#### 3.2 Per-kind hash functions

Choices here are frozen so that §2 equality and §3 hash cannot drift:

- **`nil`** → `0xB01DFACE` (fixed constant, picked to not collide with small
  fixnums). A singleton with cached hash.
- **`false`** → `0x00000000`; **`true`** → `0x00000001`. Singleton.
- **`char`** → xxHash3-32 over the scalar's 4-byte little-endian encoding,
  domain-tagged.
- **`fixnum`** → xxHash3-32 over the i48 sign-extended to 8 bytes, little-
  endian.
- **`bignum`** → xxHash3-32 over the canonical magnitude byte stream plus
  sign byte. Fixnum-range bignums are impossible by construction (they
  canonicalize); therefore `hash(fixnum(n)) ≠ hash(bignum(n))` can never
  arise for an equal pair.
- **`float`** — canonical bit pattern in (§2.2):
  - `+0.0` and `-0.0` both hash from `0x0000000000000000` (the `+0.0` bit
    pattern) so `(= 0.0 -0.0)` preserves hash equality.
  - Canonical NaN hashes from the fixed bit pattern
    `0x7FF8000000000000`.
  - Otherwise, hash is xxHash3-32 over the IEEE 754 bits.
- **`string`** — xxHash3-32 over the raw UTF-8 bytes.
- **`keyword`** — xxHash3-64 over the intern id (textual form on codec
  serialize; see §6.1). Separated from symbol hashes by the generic
  `mixKindDomain` mechanism below (each `Kind` byte lands in a distinct
  high-entropy region of `u64` space). This subsumes Clojure's
  keyword-specific `^ 0x9E3779B9` offset into a single cross-kind
  separation story.
- **`symbol`** — xxHash3-64 over the intern id (textual form on codec
  serialize). Kind-domain-mixed (see below).
- **Equality-category domain mixing.** Every full hash output has a
  **per-equality-category** offset `domain_byte * 0x9E3779B97F4A7C15`
  folded in before return. The `domain_byte` is chosen so the bedrock
  invariant `(= x y) ⇒ (hash x) = (hash y)` holds across kinds whose
  equality rule spans multiple physical kinds (§2.6 cross-category
  rule). Specifically:
    - **Kind-local equality** — every kind whose equality rule is
      confined to its own kind (nil, bool, char, fixnum, float, bignum,
      string, keyword, symbol, byte-vector, typed-vector, durable-ref,
      function, var, transient, error, meta-symbol, persistent-set):
      `domain_byte = @intFromEnum(Kind)`.
    - **Sequential category** (list, persistent-vector, and any future
      lazy-seq / cons / sequential kind): all members share
      `domain_byte = 0xF0`. Without this shared byte, `(list 1 2 3)`
      and `[1 2 3]` \u2014 required to be `=` \u2014 would hash to different
      values after domain mixing, breaking the bedrock invariant.
    - **Associative category** (persistent-map, including the
      array-map subkind): members share `domain_byte = 0xF1`. v1's
      array-map is a subkind of kind `persistent_map`, so the bytes
      coincide today; the category byte is reserved for future
      cross-kind associative equality.
  
  Scalar kinds that coincidentally share a raw payload hash
  (`fixnum(65)` / `symbol(65)` / `char(65)` / `keyword(65)`) still
  separate through the kind-local domain mixer exactly as before.
  Clojure doesn't need this machinery because the JVM gives each
  heap type its own `hashCode()` dispatch; in our single-flat-hash
  world the domain mixer replaces that discipline, with the cross-
  kind-equality categories carved out.
- **Sequential collections** — ordered combine:
  `h = 1; for each x: h = 31 * h + hasheq(x); finalize h with count`.
- **Map collections** — unordered combine over ordered (k, v) pairs:
  - Per-entry: `entry_h = 31 * (31 * 1 + hasheq(k)) + hasheq(v)` (i.e.
    `combineOrdered(combineOrdered(ordered_init, hasheq(k)), hasheq(v))`
    — two ordered combines, **no sequential finalize, no sequential
    domain byte**; the aggregate gets its own associative domain byte
    below).
  - Aggregate: `h = 0; for each entry: h += entry_h; finalize h with count`.
  - Rationale: ordered combine within each entry keeps hash sensitive
    to swapped key/value positions (stronger than Clojure's
    order-insensitive XOR); unordered combine across entries preserves
    the map's entry-order-insensitive equality. Entry hashes do not
    route through the full sequential hash pipeline — that pipeline
    would fold in the `0xF0` sequential domain byte, which is
    irrelevant for a map-internal pair and would waste a `mixKindDomain`
    call per entry. This clarification (amended 2026-04-19 during the
    CHAMP spec draft; originally wrote `h += hasheq(list(k, v))` as
    informal pseudocode that strict-read would double-domain-mix and
    finalize-with-count-2 per entry).
- **Set collections** — unordered combine:
  `h = 0; for each x: h += hasheq(x); finalize h with count`.
- **`durable-ref`** — xxHash3-32 over `store-id ++ tree-id-bytes ++
  key-bytes`. Dereferenced value is not consulted.
- **`var`** — hash over namespace/symbol pair.
- **`transient`** — throws `:no-hash-on-transient` (transients are mutable
  by definition).
- **`function`**, **`error`** — hash by heap address (identity).

Finalization: all 32-bit hashes run through `xxHash3.finalize` to scramble
low bits before storage.

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

These determine the ergonomic feel of idiomatic nexis code and are frozen.

---

### 5. Interning (PLAN §8.4)

- Keywords are globally interned; the interned id is what the Value payload
  carries. Keywords carry no metadata (hard constraint).
- Symbols are globally interned in the common case. A **metadata-bearing
  symbol** is a heap object that wraps a base symbol id plus a metadata map.
  Two metadata-bearing symbols with the same name but different metadata
  compare `=` but are not `identical?`.
- Intern ids are process-local. Serialization always emits textual form
  (PLAN §15.10) and the receiver re-interns.
- The intern table API is designed to allow future multi-isolate sharing
  (Phase 7+). v1 assumes single-isolate.

**Hash domain separation.** Keyword and symbol hashes differ by
`0x9E3779B9`. This prevents `(:foo)` and `(foo)` from collocating in the
same HAMT slot when both appear as keys in one map — essential for
keyword-keyed maps to stay collision-free under realistic workloads.

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
- `byte-vector`, `typed-vector` — yes via tagged-literal surface planned for
  v1 stdlib but **not** via bare reader syntax. Typed-vectors print as
  e.g. `#nx/f64v [1.0 2.0]` (exact syntax locked in Phase 4 alongside the
  codec). Subject to change; currently tracked as an open question in
  PLAN §24.
- `durable-ref` — yes, by its identity triple:
  `#nx/ref [<store-id> <tree-id-keyword> <key-bytes-base64>]`. Subject to
  change pre-Phase 4.

#### 6.2 Which kinds do **not** round-trip

- `function`/`closure`, `var`, `transient`, `namespace`, `tx handle`,
  `error`. These print with an `#object[...]` style marker for debugging but
  do not parse back. Matches PLAN §15.10 "not serializable".

#### 6.3 Numeric print rules

- Integers print in decimal, no leading zeros, with `-` for negatives.
  Hex/binary source literals do **not** round-trip: `(pr-str 0x2A)` is
  `"42"`, and reading `"42"` back yields the same integer value.
- Floats print with Zig's default `{d}` unless special:
  - `+inf` → `"Infinity"` reading back requires `##Inf` (reserved for Phase
    3 reader extension). Phase 0 prints `+inf` but does not commit to a
    reading syntax yet; `docs/CODEC.md` will pin this.
  - `-inf` → `"-Infinity"`; same caveat.
  - Canonical NaN → `"NaN"`; reading it back is planned as `##NaN`.
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

Copied from PLAN §8.5 so implementation can consult one file.

| Kind | Attachable? |
|---|---|
| `nil`, `bool`, `char`, `fixnum`, `bignum`, `float` | ❌ |
| `keyword` | ❌ |
| `string` | ❌ (v1) |
| `symbol` | ✅ (wrapped heap form) |
| `list`, `vector`, `map`, `set` | ✅ |
| `byte-vector`, `typed-vector` | ✅ |
| `function` / closure | ✅ |
| `var` | ✅ |
| `durable-ref` | ❌ |
| `transient` | ❌ |
| `error` | ✅ (the error map IS its metadata payload) |

Attempting `with-meta` on a non-attachable kind throws
`:no-metadata-on-immediate`. Adding a kind to the ✅ column requires a
PLAN.md amendment.

---

### 8. Deliberate non-decisions

These are explicitly **not** frozen yet; they are PLAN §24 open questions
and must not be silently decided in implementation:

- Protocols (PLAN §24.1): out of v1, no surface syntax.
- Laziness of `map`/`filter`/`reduce` (PLAN §24.2): v1 is eager, returning
  vectors.
- Record types with fixed fields (PLAN §24.10): use tagged maps in v1.
- Schema/spec (PLAN §24.5): deferred.

If you need one of these to complete Phase 0, stop and amend PLAN.md first.
