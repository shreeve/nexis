## SEMANTICS.md — Value-Layer Semantics for nexis

Truthiness, equality, hashing, nil propagation, interning, the
print/read contract and metadata: what `src/value.zig`, `src/hash.zig`
and `src/dispatch.zig` implement. The frozen decisions behind them are
PLAN §23 #10–#14, #32 and #36; PLAN wins on an apparent conflict. PLAN
§25 risk #13 (numeric corner cases poisoning equality, hash or codec)
is mitigated by pinning every edge case here.

---

### 1. Truthiness

Only `nil` and `false` are falsy (PLAN §23 #13). Everything else is
truthy, including `0`, `0.0`, `-0.0`, the infinities, NaN, `""`, the
empty collections `[]`, `{}`, `#{}`, `()`, and every char.

---

### 2. Equality (`=`)

- `(identical? x y)` is bit equality of the 16-byte Value: pointer
  identity for a heap kind (`docs/VALUE.md` §6).
- `(= x y)` is value equality, specified per kind below.

**Cross-kind rule.** Values of different kinds are never `=`, except
list and vector (§2.6). No numeric coercion, no collection–string
coercion, no keyword–symbol coercion.

#### 2.1 Nil and booleans

`(= nil nil)` is true; `(= nil false)` is false; `(= true 1)` is false.

#### 2.2 Numbers

**Integers.** One integer type in two representations: a fixnum holds
the i48 range `[-2^47, 2^47 - 1]` (`-140737488355328` to
`140737488355327`, `value.fixnum_min` / `fixnum_max`), a bignum
everything outside it. Every constructor and every arithmetic result
canonicalizes: an integer in fixnum range is always a fixnum, never a
bignum, and a zero magnitude is `fixnum(0)` whatever its sign. So two
mathematically equal integers always have one representation, and
`=` and hash agree across the boundary by construction; `(= 0 -0)` is
true.

**Cross-type equality is false** (PLAN §23 #11): `(= 1 1.0)` is false.
`==` is numeric equality under contagion: `(== 1 1.0)` is true.

**Floats (f64).**

- `(= 0.0 -0.0)` is true and the two hash alike; `(identical? 0.0
  -0.0)` is false. Storage keeps the sign.
- NaN is canonical: every NaN entering the Value layer (constructor,
  arithmetic, codec decode) is stored as `0x7FF8000000000000`. So
  `(= nan nan)` is **true**, `=` is an equivalence relation on every
  Value, and `(get (assoc m nan v) nan)` is `v`. This diverges from
  Clojure, where NaN is `=` to nothing. `==` stays IEEE: `(== nan
  nan)` is false. Arithmetic propagates NaN as IEEE does.
- `(= +inf +inf)` is true, `(= +inf -inf)` false. Subnormals compare
  numerically; there is no flush-to-zero.

**Arithmetic and ordering** (Clojure contagion):

- An operation with a float operand runs in f64 and yields a float;
  integers stay integral and exact. `(< 1 1.5)` is true, `(+ 1 0.5)`
  is `1.5`, `(max 1 2.0)` is `2.0`. A bignum operand widens to the
  nearest f64.
- `/` on two integers yields an integer when the division is exact
  and a float otherwise: `(/ 6 3)` is `2`, `(/ 7 2)` is `3.5`. There
  are no rationals (PLAN §23 #10).
- An integer result outside the fixnum range is a bignum, exact at any
  size: `(+ 140737488355327 1)` is `140737488355328`, and `(- (+
  140737488355327 1) 1)` is the fixnum again. `quot`, `rem`, `mod`,
  `abs` and unary `-` promote the same way (`(- -140737488355328)` is
  `140737488355328`). Ordering, `compare`, `max`, `min`, `zero?`,
  `pos?`, `neg?`, `even?` and `odd?` are exact over bignums.
- No arithmetic raises `:arithmetic-overflow` except
  `nexis.simd/scale` over an `i64` typed vector, whose result has no
  wider element to promote to; `nexis.simd/sum` and `dot` promote
  like `(reduce + xs)` (`docs/TYPED_VECTOR.md` §7.2).
- `zero?`, `pos?` and `neg?` are all false on NaN; `-0.0` is zero.
- Integer `/` by zero, and `quot` / `rem` / `mod` by zero of any kind,
  raise `:divide-by-zero`. Float `/` by zero is IEEE: `Infinity`,
  `-Infinity` or `NaN`.
- `even?` / `odd?` take integers only (`:kind-mismatch` on a float).
- `(long x)` is `x` for an integer and the integer part of a finite
  float, toward zero and a bignum when wide (`(long 1e30)` is
  `1000000000000000019884624838656`); NaN and the infinities raise
  `:invalid-argument`. `(double x)` is the nearest f64 of any number.

#### 2.3 Characters

Equality is Unicode scalar equality. `(= \a "a")` is false: a char is
not a length-1 string.

#### 2.4 Strings

Byte-for-byte comparison of the UTF-8 bytes, with no Unicode
normalization: a precomposed and a combining `é` are different
strings. `(= "" nil)` is false.

#### 2.5 Keywords and symbols

Equality is intern-id equality. `(= :foo :ns/foo)` is false: a
qualified and an unqualified keyword are different names. `(= 'foo
:foo)` is false, and the two kinds hash in different domains (§3.3).

#### 2.6 Collections: the three rules (PLAN §23 #36)

`src/dispatch.zig` decides every pair of values by one of three rules;
§3.3 gives each kind's rule.

| Rule | `=` | `hash` |
|---|---|---|
| **sequential** (list, vector) | element-wise, across the two kinds | ordered combine; one shared domain byte `0xF0` |
| **identity** | the same value only | the pointer; the collector never moves a block |
| **own-kind structural** | within the kind only, by the kind's structural rule | the kind's own hash; domain byte = the kind number |

- `(= (list 1 2 3) [1 2 3])` is true, and the hashes agree; a vector
  view (`(rest [1 2 3])`) is a list and follows the same rule.
- `(= (list) [])` is true; `(= () nil)` is false.
- `(= [1 2 3] #{1 2 3})` and `(= {:a 1} [:a 1])` are false.
- Maps compare entry-wise across their array-map and CHAMP layouts
  (subkinds of one kind); sets likewise.
- A record equals a record of the same type with equal field maps,
  never its field map (`docs/PROTOCOLS.md` §2.1).
- A typed vector equals a typed vector of the same element type with
  equal elements (`-0.0` equals `0.0`, NaN equals NaN); `(=
  (i64-vector [1 2]) [1 2])` and `(= (i64-vector [1 2]) (f64-vector
  [1.0 2.0]))` are false.
- A durable ref compares by its identity triple (store id, tree, key
  bytes), never by the value it points at (PLAN §23 #7). A Nextomic
  db-value compares by connection, basis and mode (`as-of`, `since`,
  `history`); an entity by its db-value and eid.

Identity kinds are mutable, process-local or code. Two atoms holding
equal values are not `=`, and an atom's hash does not change when its
value does, so a map key never becomes unequal to itself. A transient
hashes by identity and may be a map key; it equals no persistent
collection.

#### 2.7 Values nested deeper than the native stack

`=`, `hash` and printing recurse on nesting depth on the native stack.
Past the stack guard (`src/stack.zig`) they do not fault: the step that
ran out answers `false`, `0` or a `#<too deep>` marker and counts an
overflow (`dispatch.overflowCount`), and the VM turns a count that
changed across a native call or opcode into the catchable
`:stack-overflow` (`docs/VM.md` §13.1). A map, set or record whose hash
was computed past an overflow keeps no cached hash, so the wrong answer
never outlives the throw. The codec bounds nesting at 4096 levels
instead (`docs/CODEC.md` §2.7).

---

### 3. Hashing

The invariant (PLAN §23 #12 adds that metadata never contributes):

> `(= x y) ⇒ (= (hash x) (hash y))`

`test/prop/primitive.zig` checks it over random immediates, each heap
kind's property file for its kind, and `test/prop/codec.zig` C1 across
an encode–decode round trip.

#### 3.1 Scope and stability

- A hash is stable **within a process** only. None is persisted: the
  codec writes values, never hashes, and a decoded collection is
  rebuilt with the reading process's hashes. The seed, the combiners
  and the domain bytes may change freely.
- `dispatch.hashValue` returns a `u64`. The structural base of every
  heap kind is truncated to `u32` and cached in the header's `hash`
  field (`docs/HEAP.md` §1), `0` meaning "not computed"; a vector view
  caches nothing, since every offset of one vector shares its block.
- `(hash x)` in the language is `hashValue` masked to the fixnum's 47
  value bits: a non-negative fixnum.

#### 3.2 Per-kind hash functions

A hash is a per-kind **base**, then domain-mixed:
`hash = base + domain * 0x9E3779B97F4A7C15` (wrapping;
`hash.mixKindDomain`), where `domain` is the kind number, or `0xF0`
for list and vector. The mix keeps kinds whose bases coincide
(`fixnum(65)`, `char(65)`, `symbol(65)`, `keyword(65)`) apart, and
subsumes Clojure's keyword-only `^ 0x9E3779B9` offset. `xxh3` below is
xxHash3-64 seeded with the ASCII bytes `"nexis1/1"` (`hash.seed`).

- **nil** `0xB01DFACEB01DFACE`; **false** `0`; **true**
  `0x1111111111111111`.
- **char**: `xxh3` of the scalar as 4 little-endian bytes.
- **fixnum**: `xxh3` of the i64 as 8 little-endian bytes.
- **float**: `xxh3` of the IEEE bits, `-0.0` hashed as `+0.0`, NaN
  canonical.
- **keyword**, **symbol**: `xxh3` of the intern id as 8 bytes; the
  kinds differ by domain.
- **string**: `xxh3` of the bytes. **bignum**: `xxh3` of the sign byte
  and the limbs.
- **Ordered combine** (list, vector): `h = 1; for each x: h = 31*h +
  hash(x)`; finalize `h = 31*h + xxh3(count)`. `list.hashSeq` and
  `vector.hashSeq` compute the same value for the same elements.
- **Map**: per entry `31*(31*1 + hash(k)) + hash(v)`; the entries
  summed from `0`; finalized with the count as above. The ordered pair
  keeps the hash sensitive to a swapped key and value, the sum
  insensitive to entry order.
- **Set**: the elements' hashes summed from `0`, finalized with the
  count.
- **typed vector**: ordered combine over the element-type code, then
  each element (`xxh3` of the i64, or the float rule), finalized with
  the length.
- **record**: `xxh3` of the type id (4 bytes) and the field map's hash
  (8 bytes).
- **durable ref**: `xxh3` of store id, tree name and key bytes; the
  value it points at is never read.
- **Nextomic db-value**: ordered combine of the connection pointer,
  basis, `as-of`, `since` and `history`; **entity**: the db-value's
  hash combined with the eid.
- **Identity kinds**: `xxh3` of the pointer (the payload).

#### 3.3 Kinds: equality category and hash domain

The one table of which rule (§2.6) decides `=` for each kind and which
domain its hash lands in. `dispatch.zig` is its code
(`isIdentityKind`, `domainByte`); kind numbers are `docs/VALUE.md` §2.

| # | Kind | Category | Domain | `=` | Hash base (§3.2) |
|---|---|---|---|---|---|
| 0 | `nil` | own kind | 0 | always | constant |
| 1 | `false_` | own kind | 1 | always | constant |
| 2 | `true_` | own kind | 2 | always | constant |
| 3 | `char` | own kind | 3 | scalar | scalar bytes |
| 4 | `fixnum` | own kind | 4 | value | i64 bytes |
| 5 | `float` | own kind | 5 | IEEE, `-0.0 = 0.0`, NaN = NaN | bits, zero folded |
| 6 | `keyword` | own kind | 6 | intern id | id bytes |
| 7 | `symbol` | own kind | 7 | intern id | id bytes |
| 16 | `string` | own kind | 16 | bytes | bytes, cached |
| 17 | `bignum` | own kind | 17 | sign and limbs | sign and limbs, cached |
| 18 | `persistent_map` | own kind | 18 | entry-wise, both layouts | unordered, cached |
| 19 | `persistent_set` | own kind | 19 | element-wise, both layouts | unordered, cached |
| 20 | `persistent_vector` | sequential | `0xF0` | element-wise with any list or vector | ordered, cached |
| 21 | `list` (all three subkinds) | sequential | `0xF0` | element-wise with any list or vector | ordered; cached except a view |
| 23 | `typed_vector` | own kind | 23 | element type and elements | ordered, cached |
| 24 | `function` | identity | 24 | same value | pointer |
| 25 | `var_` | identity | 25 | same value | pointer |
| 26 | `durable_ref` | own kind | 26 | identity triple | triple, cached |
| 27 | `transient` | identity | 27 | same value | pointer |
| 30 | `native_fn` | identity | 30 | same value | pointer |
| 31–33 | `db_connection`, `db_write_txn`, `db_read_txn` | identity | 31–33 | same value | pointer |
| 34 | `atom` | identity | 34 | same value | pointer |
| 35 | `record` | own kind | 35 | type id and field map | type id and fields, cached |
| 36 | `protocol` | identity | 36 | same value | pointer |
| 37 | `protocol_fn` | identity | 37 | same value | pointer |
| 38 | `nextomic_conn` | identity | 38 | same value | pointer |
| 39 | `nextomic_db` | own kind | 39 | connection, basis, mode | same fields, cached |
| 40 | `nextomic_entity` | own kind | 40 | db-value and eid | same fields, cached |

The reserved kinds (22 `byte_vector`, 28 `error_`, 29 `meta_symbol`)
are never constructed; `dispatch` panics on one. A kind module
implements only its structural rule and base hash; the routing, the
identity test and the domain mix are `dispatch.zig`'s.

---

### 4. Nil propagation on collection ops

| Operation | On `nil` |
|---|---|
| `(count nil)` | `0` |
| `(seq nil)`, `(first nil)`, `(next nil)` | `nil` |
| `(rest nil)` | `()` |
| `(get nil k)` | `nil` |
| `(get nil k default)` | `default` |
| `(conj nil x)` | `(x)`, a list |
| `(assoc nil k v)` | `{k v}` |
| `(keys nil)`, `(vals nil)` | `nil`, as for `(keys {})` |
| `(flatten nil)` | `()` |
| `(select-keys nil ks)` | `{}` |

`get` returns `default` (else `nil`) only when the key is absent: `(get
{:a nil} :a 5)` is `nil`. On a receiver that is not a map, set,
vector, string or record (a number, a keyword, an atom) the key is
absent, not an error: `(get 5 :k)` is `nil`, `(get 5 :k :d)` is `:d`.
A vector or string index out of range or not an integer is absent as
well.

`rest` of a one-element sequence is `()` and `next` is `nil`; the rest
binding of a sequential destructure and of a variadic parameter is
`nil` when nothing is left (`(let [[a & r] [1]] r)` is `nil`), as in
Clojure.

The seq of a vector is a view, not a copy: `seq`, `rest`, `next`,
`nthrest`, `nthnext` and `drop` of a vector take O(1) time and space
whatever its length (`docs/LIST.md` §1), so `(loop [v v] (when (seq v)
... (recur (pop v))))` is linear. The view is a list to everything
else: `seq?` and `list?` are true, it prints as `(...)`, it is `=` to
and hashes as the list of the same elements, and the codec encodes it
as a list.

Two sequence rules follow Clojure and are easy to get backwards:

- `flatten` flattens lists and vectors only and keeps nil elements
  (`(flatten [1 nil [2]])` is `(1 nil 2)`); a non-sequential argument
  (a number, a string, a map, nil) flattens to `()`.
- A negative count means zero: `(nthrest xs -1)` is `xs`, `(split-at
  -1 xs)` is `[() xs]`, and `(take-last -1 xs)`, `(repeat -1 x)` and
  `(repeatedly -1 f)` are `()`.

Records are maps to every collection function: `count`, `empty?`,
`not-empty`, `seq`, `keys`, `conj` and `into` see the field map;
`conj`, `into` and `assoc` return a record of the same type; `(empty
r)` is `{}`.

---

### 5. Interning

- Keywords and symbols are interned (`docs/INTERN.md`); the Value's
  payload is the intern id.
- Intern ids are process-local. The codec writes the name as text and
  the reader of the bytes re-interns it (`docs/CODEC.md`).
- Keyword and symbol hashes are in different domains (§3.3), so `:foo`
  and `'foo` never share a CHAMP slot.

---

### 6. Print / read round-trip contract

For every kind that round-trips:

> `(= (read-string (pr-str v)) v)` and
> `(= (hash (read-string (pr-str v))) (hash v))`.

How each kind prints in the `pr-str` and `str` modes is
`docs/STDLIB.md` §5; this section owns which kinds round-trip.

#### 6.1 Which kinds round-trip via print/read

- `nil`, booleans, `char`, fixnum, bignum, float, string, keyword and
  symbol (as text, re-interned on read).
- `list` (a vector view included), `vector`, `map`, `set`,
  recursively.
- Not a typed vector: it prints as `#i64[1 2 3]` / `#f64[1.0 2.0]`,
  which the reader rejects at the `#`; the codec is its round trip.
- Not a record: it prints as `#ns.Type{:field value, ...}` in both
  modes, as Clojure does; the reader has no tagged literals (PLAN §24
  item 3).
- Not a durable ref: `#<durable-ref :tree hex:key-bytes>`.

#### 6.2 Kinds that print opaquely

Functions, native fns, vars, transients, atoms, protocols, protocol
fns and the db and Nextomic handles print as markers for debugging
(`#<fn>`, `#<native-fn inc>`, `#<atom>`, `#<transient>`, a var as
`#'name`) that do not read back. None is serializable either
(`docs/CODEC.md` §3).

#### 6.3 Numeric print rules

- Integers print in decimal at any size, no suffix: `(str (*
  4294967296 4294967296))` is `"18446744073709551616"`, which reads
  back as the same bignum. A hex source literal prints in decimal:
  `(pr-str 0x2A)` is `"42"`.
- Floats print as Clojure prints doubles: the shortest decimal that
  reads back to the same f64, always with a fraction (`1.0`, `2.5`,
  `100.0`), in exponent form with a one-digit integer part at or above
  `1e7` and below `1e-3` (`1.0E10`, `1.23456785E7`, `1.0E-4`).
- `0.0` prints `"0.0"` and `-0.0` prints `"-0.0"`; each reads back to
  its own bits.
- The infinities print `Infinity` / `-Infinity` and NaN prints `NaN`.
  The reader has no literal for them (`docs/FORMS.md` §8), so the text
  reads back as a symbol.

#### 6.4 Character print rules

Named: `\newline`, `\space`, `\tab`, `\return`, `\formfeed`,
`\backspace`. Printable ASCII prints as `\a` (backslash as `\\`);
everything else as `\u{HEX}`, uppercase, no leading zeros (`\u{E9}`,
`\u{0}`). The reader accepts the same set (PLAN §23 #26).

#### 6.5 String print rules

Double-quoted, escaping `\"`, `\\`, `\n`, `\t`, `\r`, and the other
ASCII controls and DEL as `\u{HEX}`; any other character prints as
itself. A string literal in source may span lines: a raw newline
inside the quotes is part of the string, and prints back as `\n`.

---

### 7. Metadata attachability

The single matrix (PLAN §23 #12, #32). `meta` on any value returns a
map or `nil`; it never throws.

| Kind | `with-meta` / `vary-meta` | `meta` |
|---|---|---|
| `list`, `vector`, `map`, `set` | a copy of the root block carrying the map; every node below the root is shared. A vector view is first rebuilt as cons cells, so the metadata does not follow `rest` into the shared vector | the map or `nil` |
| `var` | `:no-metadata-on-immediate`. A Var's metadata changes in place with `reset-meta!` / `alter-meta!`; `def`, `defn` and `defmacro` set it from `^meta` on the name, a docstring (`:doc`) and an attribute map, `defn` and `defmacro` adding `:arglists`; `:dynamic true` makes the Var dynamic | the map or `nil` |
| every other kind: `nil`, booleans, `char`, numbers, `string`, `keyword`, `symbol`, `typed-vector`, `record`, `function`, `native-fn`, `atom`, `transient`, `durable-ref`, protocols, the db and Nextomic handles | `:no-metadata-on-immediate` | `nil` |

- The metadata argument is a map or `nil` (which clears it); anything
  else is `:kind-mismatch`, checked before the target's kind.
- `reset-meta!` and `alter-meta!` take a Var; any other target is
  `:kind-mismatch`.
- Reader metadata on a collection literal attaches: `(meta ^:foo [1])`
  is `{:foo true}`.
- **Known divergence from Clojure.** Metadata stays on the value
  `with-meta` returned: `conj`, `assoc`, `dissoc`, `disj`, `pop`,
  `into`, `rest` and every other operation that builds a new
  collection return one without metadata, where Clojure carries it
  over. An update that changes nothing (`(assoc m :a 1)` when `:a` is
  already `1`) returns its argument, metadata included.
- Metadata never takes part in `=`, `hash`, printing or the codec:
  `(= v (with-meta v m))` is true and the two hash alike.

---

### 8. Open questions and absences

What the language deliberately leaves out, from the code; changing any
of these is a PLAN amendment first (AGENTS.md).

- **Laziness** (PLAN §24 item 2; §23 #14). Every sequence function is
  eager: `map`, `filter`, `for` and friends return realized lists
  (`mapv` and `filterv` vectors), and `(range)` or `(iterate f x)`
  without a bound is `:arity-mismatch`.
- **Schema or spec** (PLAN §24 item 5): none.
- **`&form` and `&env`** (PLAN §24 item 13; §23 #34): a macro receives
  its arguments only.
- **Tagged literals** (PLAN §24 item 3): none; records and typed
  vectors do not read back (§6.1).
- **Protocols and records exist** (PLAN §23 #8, `docs/PROTOCOLS.md`);
  multimethods do not (§23 #9).
