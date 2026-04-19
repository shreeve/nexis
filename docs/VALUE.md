## VALUE.md — Runtime Value Layer (Phase 1)

**Status**: Phase 1 deliverable. Authoritative physical-layout contract for
the runtime `Value` type and the heap-object header that backs non-immediate
kinds. Derivative from `PLAN.md` §8 and §23; PLAN.md wins on conflict.

Risk-register entries #1 (three-representations boundary) and #3 (eq/hash
inconsistency) are the two this document is built to prevent. Every
physical-bit decision here is frozen; changing one requires a PLAN
amendment and a re-run of the Phase 1 gate tests (PLAN §20.2).

---

### 1. Value — the 16-byte tagged cell

```zig
pub const Value = extern struct {
    tag: u64,
    payload: u64,
};
```

Total 16 bytes. `extern struct` guarantees a stable C-ABI layout (no
field reordering, no padding surprise) and fits exactly one 128-bit SIMD
register on NEON and SSE (PLAN §19.6 Tier 1 win T1.2).

#### 1.1 Tag word bit layout (little-endian)

| Bits | Field | Purpose |
|---|---|---|
| `0..7` | `kind: u8` | Primary discriminator (§2 kind table) |
| `8..15` | `flags: u8` | `has_meta`, `hash_cached`, `durable`, `interned`; reserved bits = 0 |
| `16..31` | `subkind: u16` | Heap-kind sub-type when `kind` names a heap family |
| `32..63` | `aux: u32` | Per-kind auxiliary: length prefix, cached hash low bits, intern-table version hint |

Accessors (`Value.kind()`, `.flags()`, `.subkind()`, `.aux()`) read these
bit fields via bit shifts; the tag word is never modified directly outside
the canonical constructors (§3).

#### 1.2 Payload word interpretation

Determined entirely by `kind`. Exhaustive table in §2. The `payload` field
is `u64` — interpretation (signed int, float bits, pointer, intern id)
happens at the accessor boundary, never implicitly.

#### 1.3 Why not NaN-boxing

PLAN §23 decision 1 freezes the plain 16-byte struct over NaN-boxing. The
alternative would pack everything into 8 bytes using NaN payload bits for
non-float tags. Rejected for v1 because:

- Doubled register pressure on equality / move / load paths is acceptable.
- Debuggers, disassemblers, and core dumps read the struct layout
  directly; NaN-boxing is hostile to those tools.
- Heap pointers on macOS-arm64 already consume 48 bits; NaN-boxing
  assumes 48-bit canonical pointers, which AArch64 breaks under
  pointer authentication (PAC) features we might eventually adopt.

Reviewable in v3+ if profile data shows the indirection hurting.

---

### 2. Kind discriminator

Canonical `kind: u8` values. Numeric assignments are frozen so that the
runtime switch dispatcher can use them as jump-table indices in Phase 2
and beyond without any re-mapping layer.

#### 2.1 Immediates (payload lives in the `Value` itself)

| # | `kind` | Name | Payload interpretation | Notes |
|---|---|---|---|---|
| 0 | `nil` | nil | unused (must be 0) | Singleton value. All-zero `Value{}` **is** `nil`. |
| 1 | `false_` | bool false | unused (must be 0) | Reserved alongside `true_` for zero-cost dispatch. |
| 2 | `true_` | bool true | unused (must be 0) | |
| 3 | `char` | Unicode scalar | `payload[0..32] = u21` scalar, upper bits zero; surrogate range (D800..DFFF) rejected at construction | |
| 4 | `fixnum` | i48 integer | `payload` = sign-extended to i64; only values in `[-(1<<47), (1<<47)-1]` are representable. Out-of-range uses `bignum` | |
| 5 | `float` | f64 | `payload = @bitCast(u64, f)` — the bit pattern of a canonical-form f64 (SEMANTICS §3.2). Incoming NaN is canonicalized to `0x7FF8000000000000` at construction | |
| 6 | `keyword` | interned keyword id | `payload[0..32] = u32` intern id. Hash-domain offset (`0x9E3779B9`) applied in `hash()` only | |
| 7 | `symbol` | interned symbol id | `payload[0..32] = u32` intern id. Metadata-bearing symbols live on the heap (see §2.2) | |

**Canonical-NaN discipline.** `float` values round-trip through
canonicalization on every entry path (constructor, codec decode,
arithmetic result that produces NaN). The runtime never observes a
non-canonical NaN bit pattern inside a `Value` with `kind = .float`. This
is what makes `(= nan nan)` reflexive (SEMANTICS §2.2) and hash
consistency trivial.

**Signed-zero and NaN behaviour matrix.** Three-way split between
`identical?`, `=`, and `hash`:

| Input | `identical?` | `=` | `hash` |
|---|---|---|---|
| `+0.0` vs `+0.0` | true | true | equal |
| `-0.0` vs `-0.0` | true | true | equal |
| `+0.0` vs `-0.0` | **false** (bit patterns differ) | true (IEEE) | equal (collapses to `+0.0` at hash time) |
| canonical NaN vs canonical NaN | true (both canonicalized) | **true** (reflexive per SEMANTICS §2.2) | equal |
| non-canonical NaN input | *never occurs* — `fromFloat` canonicalizes on the way in | — | — |

**`nil == Value{}`.** The zero-bit `Value` is `nil` by construction.
Freshly-allocated memory is therefore `nil`-valued without explicit
initialization; this property is relied on by the frame-slot allocator
(PLAN §13.1).

#### 2.2 Heap-allocated (payload is a 16-byte-aligned pointer)

Payload = `u64` pointer to a heap object with a standard `HeapHeader`
(§4). `subkind` disambiguates families where the coarse `kind` is shared.

| # | `kind` | Name | subkind uses |
|---|---|---|---|
| 16 | `string` | UTF-8 string | 0 = inline short string (≤ 15 bytes, bytes live in payload + aux); 1 = heap string; 2 = zero-copy slice over mmap page (Phase 6 T2.2) |
| 17 | `bignum` | arbitrary-precision integer | 0 = limbs stored in heap object |
| 18 | `persistent_map` | CHAMP map | 0 = array-map (inline ≤8 entries); 1 = CHAMP node tree |
| 19 | `persistent_set` | CHAMP set | same as map |
| 20 | `persistent_vector` | 32-way persistent vector | 0 = inline (≤32); 1 = trie + tail |
| 21 | `list` | cons list | 0 = normal cons; 1 = empty singleton |
| 22 | `byte_vector` | packed u8 slice | |
| 23 | `typed_vector` | homogeneous numeric slice | 0 = i32, 1 = i64, 2 = f32, 3 = f64 |
| 24 | `function` | compiled routine + upvalues | 0 = fn, 1 = closure, 2 = macro-valued var callee |
| 25 | `var_` | namespace var cell | |
| 26 | `durable_ref` | emdb identity triple | |
| 27 | `transient` | mutable wrapper | subkind mirrors the inner collection kind |
| 28 | `error_` | exception value | |
| 29 | `meta_symbol` | metadata-bearing symbol wrapper | wraps base-symbol id + meta map (PLAN §8.4) |

Values 8–15 are **reserved** for future immediate kinds (e.g. a second
fixnum flavor, or a tagged inline byte burst). Values 30–63 are
**reserved** for future heap kinds. Values 64+ are **reserved** for
runtime-private use (internal sentinels that must never escape a public
API).

#### 2.3 Sentinel values (runtime-private)

| Sentinel | Purpose |
|---|---|
| `unbound` (kind = 64) | `Var.root` when the var has no root (PLAN §13.3). Calling an unbound var throws `:unbound-var`. Never serializable. |
| `undef` (kind = 65) | Compile-time placeholder in IR construction. Never reaches the VM. |

Sentinels satisfy `identical?` but never `=` — attempting `(= unbound x)`
at the language level throws `:sentinel-escape`, since a user-observable
sentinel is a bug somewhere upstream.

---

### 3. Canonical constructors (day-one invariant enforcement)

Every immediate kind has exactly one public constructor that enforces the
invariants in §2 before the `Value` escapes. Raw field writes are package-
private.

```zig
pub fn nil() Value;
pub fn fromBool(b: bool) Value;
pub fn fromChar(scalar: u21) ?Value;          // null on surrogate
pub fn fromFixnum(n: i64) ?Value;             // null on out-of-range
pub fn fromFloat(f: f64) Value;               // canonicalizes NaN
pub fn fromKeyword(intern_id: u32) Value;
pub fn fromSymbol(intern_id: u32) Value;
```

Heap-pointer constructors are internal to the heap module and wrap a
`*HeapHeader` into a `Value` with the correct kind + flags.

**Why nullable returns for char/fixnum.** The constructor either yields a
fully-valid `Value` or rejects the input. A nullable return forces the
caller to handle the out-of-range / surrogate case explicitly; a panic on
invalid input would hide the range check from the type system.

**`fromFloat` is infallible** because every f64 bit pattern maps to a
valid `Value`, via NaN canonicalization when needed. Callers that care
about distinguishing "was this a NaN?" call `isNaN()` on the resulting
`Value`.

---

### 4. HeapHeader — shared by every heap-allocated Value

```zig
pub const HeapHeader = extern struct {
    kind: u16,          // finer-grained than Value.tag.kind
    mark: u8,           // GC bits (§5)
    flags: u8,          // has_meta, interned, immutable, zero_copy, ...
    hash: u32,          // cached hash; 0 = uncomputed sentinel
    meta: ?*HeapHeader, // optional metadata map (PLAN §8.5)
    // body follows
};
```

16 bytes before the kind-specific body. `meta` is a pointer to another
`HeapHeader` (the root of a persistent-map Value) rather than a
`*Value` because the metadata root is always a map; no tag is needed.

**Hash caching.** A cached hash of `0` means "not yet computed." The
value `0` is a tiny fraction of the 32-bit range; on the rare collision,
we pay the recomputation cost once. Saves one u32 and one flag bit per
heap object over a separate `hash_valid` flag.

**Alignment.** The allocator returns 16-byte-aligned `HeapHeader*`
pointers. This lets us stash up to 4 bits of tag into a pointer's low
bits in a future NaN-boxing migration without touching the heap layout.

---

### 5. GC bits (placeholder spec — pinned here so collectors can evolve)

The `mark: u8` field uses two bits in v1:

| Bit | Name | Meaning |
|---|---|---|
| 0 | `marked` | Visited in the current mark phase |
| 1 | `pinned` | Do not free; live root |
| 2..7 | reserved | Future generational / tri-color / remembered-set use |

Phase 1 GC is precise stop-the-world mark-sweep (PLAN §23 #2, #18).
`marked` is cleared by sweep; `pinned` is set by open transactions /
durable-ref handles / REPL history / intern tables (PLAN §10.5).

---

### 6. Equality and hash obligations

The Value layer must satisfy, for every `x` and `y`:

```
(identical? x y) ⇒ (= x y)
(= x y)          ⇒ (hash x) = (hash y)
```

No exception. Phase 1 gate test #1 (PLAN §20.2) checks this across 100k+
randomized pairs drawn from every kind. Implementation obligations:

- `identical?` is bit-equality on the 16-byte struct for immediates; for
  heap kinds, pointer identity on the `HeapHeader*` (the same header
  pointer in two different `Value` wrappers still satisfies identity).
- `=` follows SEMANTICS.md §2 exactly. Cross-category false. Canonical
  NaN reflexive. Cross-type numeric false (no `1 == 1.0`).
- `hash` follows SEMANTICS.md §3.2 per-kind table. Hash-domain offset
  for keyword/symbol separation enforced in `Value.hash()`, not in the
  raw intern-id hash.

---

### 7. What VALUE.md does not cover

- **Memory layout of specific heap kinds** (string body, HAMT node,
  RRB trie) — lives in the per-module docs (`docs/COLL.md` pending).
- **Serialization wire format** — lives in `docs/CODEC.md` (frozen
  Phase 4).
- **GC roots and sweep algorithm** — lives in PLAN §10; detailed
  procedure will land in `docs/GC.md` when sweep ships.
- **Durable-ref identity triple** — lives in PLAN §15.2 and
  `docs/DB.md` (future).

If you need one of these to proceed with a Phase 1 module, stop and draft
the companion doc first. The Phase 0 lesson: spec-first, even when the
code shape seems obvious.
