## CODEC.md — Durable Wire Format (Phase 1)

**Status**: Phase 1 deliverable. Authoritative wire-format and API
contract for `src/codec.zig`. Derivative from `PLAN.md` §15.6 /
§15.10 / §23 #25 (serialization scope frozen), `docs/SEMANTICS.md`
§2.2 / §3.2 (numeric canonical form + hash invariants), and
`docs/VALUE.md` §2 (Kind numbering). Those documents win on
conflict. Reviewed peer-AI turn 20.

This commit upgrades CODEC.md from the Phase 0 stub state to a full
Phase 1 specification. The previous stub punted exact byte layout
and varint choice to Phase 4; this amendment pins a **v1 interim
wire format** sufficient to close PLAN §20.2 **gate test #5 (codec
round-trip)** while leaving room for a Phase 4 "v2" format via the
version envelope. Cross-process byte-canonicality for
collections with non-deterministic iteration order (map, set)
remains a Phase 4 concern; within-process round-trip equality +
hash preservation is v1's contract.

---

### 1. Scope

**In (v1 codec):**
- Every kind allocatable in the v1 runtime: `nil`, `false_`,
  `true_`, `char`, `fixnum`, `float`, `keyword`, `symbol`,
  `string`, `bignum`, `list`, `persistent_vector`,
  `persistent_map`, `persistent_set`.
- Encode: `Value → []u8`. Decode: `[]u8 → Value`.
- Version envelope for future format evolution.
- Deterministic within-process round-trip: `(= v (decode(encode(v))))`
  and `hash(v) = hash(decode(encode(v)))`.

**Out (v1 codec):**
- `byte_vector`, `typed_vector`, `durable_ref`: kinds reserved in
  VALUE.md §2 but not yet allocatable in the runtime. Public
  codec API returns `error.UnserializableKind` if encountered;
  internal assertions may panic loudly for truly-impossible inputs
  (peer-AI turn 20 wording nuance: public API = typed error;
  "this can't happen" = assert).
- `function`, `var_`, `transient`, `error_`, `meta_symbol`:
  non-serializable per PLAN §15.10 + §23 #25. Public API returns
  `error.UnserializableKind`.
- **Metadata is never serialized in v1.** SEMANTICS §7 /
  PLAN §8.5: metadata never participates in equality or hash; the
  codec respects this by discarding `HeapHeader.meta` during
  encode. Decode produces values with `h.meta = null` always —
  the allocator's zero-init contract (HEAP.md §1 invariant 4)
  guarantees this for free; decode never calls `setMeta`.
  Round-trip equality is unaffected because metadata never
  participates in equality (PLAN §23 #12).
- **Cross-process byte-canonicality** for map/set (sorted-key
  encoding). v1 encodes in iteration order. Phase 4 can add a
  canonical-order minor version.
- **Schema-aware compact encoding** (skipping redundant kind
  tags when a sequential/associative container's element type is
  homogeneous). Phase 4+ optimization.

---

### 2. Wire format — v1

**Envelope (top level only, peer-AI turn 20):**

```
[major: u8 = 1] [minor: u8 = 0] [ValueEncoding]
```

The envelope appears **exactly once**, at the outermost frame of a
call to `encode`. Recursive nested values inside a container
(e.g., list elements, map keys/values) carry only their per-kind
encoding, not a nested envelope.

Major version bumps indicate breaking format changes. Minor
version bumps indicate non-breaking additions (new kinds, new
optional subformats). v1 ships `[1, 0]`. Phase 4's real canonical
format may bump to `[2, 0]` if it's byte-incompatible or
`[1, 1]` if additive.

**Per-kind `ValueEncoding`** (kind byte always first, matching
VALUE.md §2 numeric values):

| Kind | Bytes |
|---|---|
| `nil` (0) | `[0]` |
| `false_` (1) | `[1]` |
| `true_` (2) | `[2]` |
| `char` (3) | `[3] [u32 LE = Unicode scalar]` |
| `fixnum` (4) | `[4] [zigzag LEB128 = sign-encoded i48 value]` |
| `float` (5) | `[5] [u64 LE = IEEE 754 bits, canonical NaN]` |
| `keyword` (6) | `[6] [unsigned LEB128 len] [UTF-8 name bytes]` |
| `symbol` (7) | `[7] [unsigned LEB128 len] [UTF-8 name bytes]` |
| `string` (16) | `[16] [unsigned LEB128 len] [UTF-8 bytes]` |
| `bignum` (17) | `[17] [negative: u8 ∈ {0,1}] [unsigned LEB128 limb_count] [u64 LE × limb_count]` |
| `persistent_map` (18) | `[18] [unsigned LEB128 count] [(key ValueEncoding, value ValueEncoding) × count]` |
| `persistent_set` (19) | `[19] [unsigned LEB128 count] [element ValueEncoding × count]` |
| `persistent_vector` (20) | `[20] [unsigned LEB128 count] [element ValueEncoding × count]` |
| `list` (21) | `[21] [unsigned LEB128 count] [element ValueEncoding × count]` |

#### 2.1 Varint choice

- **Unsigned LEB128** for all lengths / counts (strings,
  keyword/symbol names, list/vector/map/set counts, bignum limb
  counts). Standard, compact, stdlib-friendly.
- **Signed ZigZag LEB128** for `fixnum` values (peer-AI turn 20
  pushback on fixed-width i64). Small integers (the common case)
  encode in 1–2 bytes; worst-case i48 fits in 8 bytes (one more
  byte than fixed i64 LE, but rare). Net win for realistic
  workloads.
- **Fixed little-endian for float / char** — the IEEE 754 bits and
  the `u21` Unicode scalar are both fixed-size inputs with no
  common-case compression benefit.
- **Fixed little-endian for bignum limbs** — bignum magnitudes are
  large by definition (canonicalization guarantees magnitude >
  i48 range per BIGNUM.md §1). Varint overhead per limb would be
  wasted.

#### 2.2 Keyword / symbol / string byte-exactness

Encoded as length-prefixed **raw bytes** of the interned name (for
keyword / symbol) or the string body (for string). Byte-exact;
codec does NOT validate UTF-8 at the encode or decode boundary.

Rationale (STRING.md §2 invariant 4 + INTERN.md §1 invariant 4):
runtime-constructed strings / keyword / symbol names are byte-
exact and may in principle contain non-UTF-8 bytes (reader grammar
produces valid UTF-8, but direct API calls like `string.fromBytes`
pass bytes through verbatim). A codec that rejected non-UTF-8
input would break the round-trip invariant for such values. Decode
reconstructs byte-for-byte.

Keyword / symbol decode re-interns via the supplied `*Interner`,
producing a fresh intern id that may differ from the original
process's id but refers to the same logical name. Round-trip
equality holds because keyword / symbol equality compares intern
ids which resolve to the same byte sequence.

#### 2.3 Bignum sign byte

Strictly `0` (non-negative) or `1` (negative). Decode rejects any
other byte value with `error.MalformedPayload`.

#### 2.4 Float canonical NaN

Encode: `hash.canonicalizeFloat(f)` normalizes NaN to
`0x7FF8000000000000` bits before emitting. Decode: `fromFloat(bits)`
re-canonicalizes any NaN bits on the way back in. `-0.0` is
preserved bit-exact on both sides (SEMANTICS §2.2: `identical?`
distinguishes `-0.0` from `+0.0`; codec must too).

#### 2.5 Map / set iteration order — NOT canonical

Map and set encoding traverses the inner structure in **iteration
order** (whatever `MapIter` / `SetIter` produces). This gives
**within-process round-trip equivalence** (decode produces a
structurally-equal collection) but does NOT guarantee
**byte-canonical encoding across different construction
histories**. Two logically-equal maps built by different insertion
orders may encode to different byte sequences.

Gate #5 (`decode(encode(v)) = v`) is satisfied; a hypothetical
"canonical byte form for content-addressed storage" is NOT
satisfied. Phase 4+ can add a minor-version bump introducing
sorted-by-key encoding when that requirement lands.

#### 2.6 Decode canonicalization policies (peer-AI turn 20)

Decode is **lenient** about input that is structurally valid but
not canonical. Policies:

- **Bignum non-canonical input**: if the decoded bignum has zero
  magnitude, trailing zero limbs, or a magnitude that fits in
  fixnum range, decode **accepts** the input and canonicalizes via
  the normal `bignum.fromLimbs` constructor (which folds to
  `fixnum(0)` for zero, `fixnum(N)` for fixnum-range, and trims
  trailing zeros). The resulting `Value` may be `.fixnum`, not
  `.bignum`, depending on the canonicalization outcome. Round-trip
  equality is preserved because `hash(bignum(N)) == hash(fixnum(N))`
  never arises — canonicalization ensures only one representation
  exists per mathematical value (BIGNUM.md §1).
- **Map / set with duplicate keys / elements**: reconstruction
  proceeds via normal `mapAssoc` / `setConj` which handle
  duplicates (later wins for map; deduplicated for set). Decode
  does NOT reject duplicates; the reconstructed collection's count
  reflects unique entries only.
- **NaN bit patterns that aren't canonical**: decode re-canonicalizes
  via `value.fromFloat`. Any NaN input produces the canonical NaN
  output bits.

Encode **always produces canonical output** for these cases (e.g.,
encode never emits a non-canonical bignum in v1). Decode leniency
is defensive against input that a Phase 4+ encoder, older encoder
version, or external producer might emit.

---

### 3. Non-serializable kinds

From PLAN §15.10 / §23 #25 (frozen):

| Kind | Reason |
|---|---|
| `function` / closure | Code, upvalues, captured VM state are process-local. |
| `var_` | Identity + mutation machinery are process-local. Serialize the root value instead. |
| `transient` | Mutable by definition. Only `persistentBang`-ed results cross the codec. |
| `namespace` | Process-local binding table (Phase 3). |
| `tx handle` / `emdb.Env` connection | Open OS resources. |
| `error_` | Stack traces carry process-local frame references. |
| `meta_symbol` | Reserved; not yet allocated; non-serializable per metadata discipline. |
| `byte_vector`, `typed_vector`, `durable_ref` | Reserved kinds not yet implemented; will serialize when their modules ship (Phase 4+). |

Attempting to encode any of these returns
`error.UnserializableKind` at the public API. No silent stubs, no
lossy round-trips.

---

### 4. Round-trip invariant (formal)

For every Value `v` in the v1 Serializable set (§1 "In"):

```
(= v (decode(encode(v))))                           — structural equality
(= (hash v) (hash (decode(encode(v)))))             — hash preservation
(encode v) == (encode (decode(encode(v))))          — byte-stable re-encode
                                                      for canonical-order kinds
                                                      (scalars, strings, bignums,
                                                      vectors, lists). NOT for
                                                      map/set per §2.5.
```

This is **PLAN §20.2 gate test #5** — exercised on 10k+ randomized
values in `test/prop/codec.zig`.

---

### 5. Public API

```zig
pub const CodecError = error{
    /// Attempt to encode/decode a kind excluded from the v1
    /// Serializable set (§1 "Out"): function, var_, transient,
    /// namespace, error_, meta_symbol, byte_vector, typed_vector,
    /// durable_ref.
    UnserializableKind,

    /// Decode ran out of bytes mid-value.
    TruncatedInput,

    /// `decode` consumed a valid value but input has extra bytes.
    /// Exactly one envelope + body expected per decode call.
    TrailingBytes,

    /// Envelope version bytes don't match a version this build
    /// understands. v1 accepts only `[1, 0]`.
    InvalidVersion,

    /// First byte of a ValueEncoding doesn't map to any recognized
    /// Kind in v1's Kind enum (i.e., byte is outside the valid
    /// numeric range). Distinct from `UnserializableKind`, which is
    /// returned when the kind IS recognized but not v1-serializable.
    InvalidKindByte,

    /// Per-kind payload field is structurally invalid: bignum sign
    /// byte not in {0, 1}, or similar per-kind field that doesn't
    /// fit a more specific error. Peer-AI turn 21 recommendation
    /// against overloading `InvalidKindByte` for per-kind fields.
    MalformedPayload,

    /// Unsigned LEB128 decode produced a value that doesn't fit
    /// in u64, or the encoding itself is malformed (e.g., 11+
    /// continuation bytes).
    InvalidLeb128,

    /// Char encoding decoded to a surrogate (0xD800..0xDFFF) or
    /// value > 0x10FFFF. Matches `value.fromChar` rejection.
    InvalidCharScalar,
};

pub fn encode(
    allocator: std.mem.Allocator,
    v: Value,
) (CodecError || std.mem.Allocator.Error)![]u8;

pub fn decode(
    heap: *Heap,
    interner: *Interner,
    bytes: []const u8,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) (CodecError || std.mem.Allocator.Error || error{Overflow})!Value;
```

**`encode`** walks the Value graph (recursively for containers),
appending bytes to a growing buffer via the supplied allocator.
Returns the owned byte slice; caller frees.

**`decode`** consumes `bytes` completely; any trailing input
triggers `error.TrailingBytes`. Takes `*Heap` (for allocating
strings / bignums / collections), `*Interner` (for re-interning
keywords / symbols), and hash/eq callbacks (for reconstructing
maps/sets via `hamt.mapAssoc` / `setConj`).

Neither function mutates the input or any existing Value — both
are pure producers.

---

### 6. One-way terminal module (dispatch/gc/transient discipline)

`codec.zig` imports every kind module that has serializable
content. Nothing imports `codec.zig`:

```
src/codec.zig
├── @import("value")
├── @import("heap")
├── @import("intern")
├── @import("hash")
├── @import("string")
├── @import("bignum")
├── @import("list")
├── @import("vector")
└── @import("hamt")
```

This matches the `src/dispatch.zig` / `src/gc.zig` / `src/coll/transient.zig`
one-way-terminal pattern.

---

### 7. Testing

Inline tests in `src/codec.zig`:
- Each kind's trivial round-trip (empty string / small fixnum /
  empty map / nested list-of-lists).
- Envelope rejection: wrong major / minor version bytes return
  `InvalidVersion`.
- Truncation rejection for a half-written envelope.
- Trailing-byte rejection.
- Malformed varint rejection.
- Malformed UTF-8 rejection.
- Surrogate char rejection.
- Invalid-kind-byte rejection.
- `UnserializableKind` on encoding a transient wrapper.
- Canonicalization policies (§2.6): bignum with trailing zeros
  round-trips to a fixnum; map with duplicate keys in byte input
  round-trips to a deduplicated map.

Property tests in `test/prop/codec.zig`:

**C1. 10k round-trip (GATE TEST #5 RECEIPT)**: generate 10,000
random Values across every serializable kind, nested up to depth
4. For each:
  - `encode(v)` succeeds.
  - `decode(encode(v))` succeeds.
  - `dispatch.equal(v, decode(encode(v)))` is true.
  - `dispatch.hashValue(v) == dispatch.hashValue(decode(encode(v)))`.

**C2. Re-encode byte-equality (canonical-order kinds)**: for
scalars, strings, bignums, vectors, and lists generated in C1:
  - `encode(v) == encode(decode(encode(v)))` (byte slices equal).

Map and set are explicitly excluded from C2 per §2.5 — their
iteration order depends on internal structure which may differ
between equal values built via different paths.

**C3. Non-serializable rejection**: encode of a transient returns
`UnserializableKind`.

**C4. Corrupted-input defense**: random byte slices fed to decode
either succeed (producing some Value) or return a `CodecError`;
no panic, no infinite loop, no memory corruption. 1000 trials of
random bytes.

Together C1+C3 deliver the PLAN §20.2 gate test #5 receipt. C2
strengthens the invariant for canonical-order kinds. C4 is a
general robustness property against malformed input.

---

### 8. Deferred (explicitly)

- **Cross-process byte-canonicality** for maps and sets (sorted
  keys). Phase 4+ minor version bump.
- **Schema-aware encoders** that skip redundant kind tags for
  homogeneous containers. Phase 4+ optimization.
- **Streaming encoder / decoder** (`*std.Io.Writer` / `*std.Io.Reader`
  variants). Phase 4+; v1 uses fully-buffered encode/decode.
- **Byte-vector / typed-vector / durable-ref serialization.** Kinds
  not yet allocatable; ship with the respective kind modules.
- **Versioned compact bignum encoding.** Current limbs-in-bytes
  format is simple but not maximally compact for small bignums
  (which are rare by canonicalization). Phase 4+ if profiling
  justifies.
- **Emdb integration** (`src/db.zig`) — codec bytes become the
  value half of durable-ref key-value pairs. Phase 4 per PLAN §21.

---

### 9. Amendment note

This file replaces the Phase 0 stub version of CODEC.md. Previous
content said "Exact byte layout per kind / Varint choice /
Versioning byte(s) — all Phase 4 deliverables." Phase 1 needed a
concrete implementation to close gate test #5; this amendment
pins a v1 interim wire format that satisfies the gate with
room for a Phase 4 canonical format evolution via the version
envelope.

The v1 format is considered **stable within a process for Phase 1
purposes** but NOT frozen for cross-version byte compatibility.
Phase 4 is the final byte-freeze point; any changes at that time
will bump the major or minor version in the envelope.
