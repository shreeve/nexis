## CODEC.md — Durable Wire Format

Authoritative wire-format and API contract for `src/codec.zig`. Derivative from `PLAN.md` §15.6 /
§15.10 / §23 #25 (serialization scope frozen), `docs/SEMANTICS.md`
§2.2 / §3.2 (numeric canonical form + hash invariants), and
`docs/VALUE.md` §2 (Kind numbering). Those documents win on
conflict.

The format is the **v1 wire format**, the value half of every durable
ref and the Nextomic transaction log: bytes written by one process are
read by another, so the format is frozen (§9). It satisfies the PLAN
§20.2 codec round-trip property and leaves room for a successor via the
version envelope. Cross-process byte-canonicality for collections with
non-deterministic iteration order (map, set) is not provided.

---

### 1. Scope

**In (v1 codec):**
- The data kinds: `nil`, `false_`, `true_`, `char`, `fixnum`,
  `float`, `keyword`, `symbol`, `string`, `bignum`, `list`,
  `persistent_vector`, `persistent_map`, `persistent_set`,
  `typed_vector`, nested at most `max_depth` (4096) deep (§2.7).
- Encode: `Value → []u8`. Decode: `[]u8 → Value`.
- Version envelope for future format evolution.
- Deterministic within-process round-trip: `(= v (decode(encode(v))))`
  and `hash(v) = hash(decode(encode(v)))`.

**Out (v1 codec):**
- Every other kind (§3): identity-valued, mutable or process-local.
  Encode returns `error.UnserializableKind`; decode returns the same
  error for a byte that names such a kind.
- **Metadata is never serialized.** SEMANTICS §7 /
  PLAN §8.5: metadata never participates in equality or hash; the
  codec respects this by discarding `HeapHeader.meta` during
  encode. Decode produces values with `h.meta = null` always —
  the allocator's zero-init contract (HEAP.md §1 invariant 4)
  guarantees this for free; decode never calls `setMeta`.
  Round-trip equality is unaffected because metadata never
  participates in equality (PLAN §23 #12).
- **Cross-process byte-canonicality** for map/set (sorted-key
  encoding). v1 encodes in iteration order. A canonical-order minor
  version would add it.
- **Schema-aware compact encoding** (skipping redundant kind
  tags when a sequential/associative container's element type is
  homogeneous).

---

### 2. Wire format — v1

**Envelope (top level only):**

```
[major: u8 = 1] [minor: u8 = 0] [ValueEncoding]
```

The envelope appears **exactly once**, at the outermost frame of a
call to `encode`. Recursive nested values inside a container
(e.g., list elements, map keys/values) carry only their per-kind
encoding, not a nested envelope.

Major version bumps indicate breaking format changes. Minor
version bumps indicate non-breaking additions (new kinds, new
optional subformats). The version is `[1, 0]`. A canonical
format would bump to `[2, 0]` if it's byte-incompatible or
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
| `typed_vector` (23) | `[23] [elem: u8 ∈ {1 = i64, 3 = f64}] [unsigned LEB128 count] [u64 LE × count]` — i64 as two's-complement bits, f64 as canonical IEEE bits (`docs/TYPED_VECTOR.md` §4) |

#### 2.1 Varint choice

- **Unsigned LEB128** for all lengths / counts (strings,
  keyword/symbol names, list/vector/map/set counts, bignum limb
  counts). Standard, compact, stdlib-friendly.
- **Signed ZigZag LEB128** for `fixnum` values (not fixed-width
  i64). Small integers (the common case)
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
- **Fixed little-endian for typed-vector elements** — the elements
  are unboxed `i64` / `f64` in memory; the wire form is the same
  eight bytes each. An element tag other than 1 or 3 is
  `MalformedPayload`.
- **Every length and count is bounded by the input before anything
  is allocated for it.** A LEB128 value can be anything up to
  2^64 − 1, so decode compares it with the bytes that remain, never
  adds it to the cursor: each string byte, list, vector or set
  element takes at least one byte, each map entry two, each limb or
  typed-vector element eight. A count past what remains is
  `TruncatedInput`, never an overflow or an allocation sized by the
  count. The tenth byte of a LEB128 may carry only bit 63; more is
  `InvalidLeb128`. Overlong encodings (`80 00` for 0) name the same
  number and are accepted; encode never writes them.

#### 2.2 Keyword / symbol / string byte-exactness

Encoded as length-prefixed **raw bytes** of the interned name (for
keyword / symbol) or the string body (for string). Byte-exact;
codec does NOT validate UTF-8 at the encode or decode boundary
(`docs/STRING.md` §2.4 states the same).

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
satisfied. A minor-version bump introducing sorted-by-key encoding
would satisfy it.

#### 2.6 Decode canonicalization policies

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
- **Map / set with duplicate keys / elements**: encode never writes
  one, so a map or set whose decoded distinct entries fall short of
  its count is corrupt input: `MalformedPayload`. A corrupt file
  never decodes silently to different data.
- **NaN bit patterns that aren't canonical**: decode re-canonicalizes
  via `value.fromFloat`. Any NaN input produces the canonical NaN
  output bits.

Encode **always produces canonical output** for these cases (e.g.,
encode never emits a non-canonical bignum). Decode leniency
is defensive against input that another encoder version or an
external producer might emit.

#### 2.7 Nesting depth

The outermost value is at depth 0 and a container's elements sit one
deeper. `codec.max_depth` is 4096: encode refuses a value with anything
deeper as `UnserializableKind` (a catchable error at the language
boundary, never a crash), and decode treats deeper input as
`MalformedPayload` (corrupt: encode never writes it). One bound on both
sides means every value written reads back. Both recursions keep a
nesting level to two small frames (well under 1 KiB in Debug builds),
so the bound fits the default 8 MiB stack in every build mode.

---

### 3. Non-serializable kinds

From PLAN §15.10 / §23 #25 (frozen):

| Kind | Reason |
|---|---|
| `function`, `native_fn` | Code, upvalues, captured VM state are process-local. |
| `var_` | Identity + mutation machinery are process-local. Serialize the root value instead. |
| `transient` | Mutable by definition. Only `persistentBang`-ed results cross the codec. |
| `atom` | A mutable identity (`docs/ATOM.md` §6). |
| `record`, `protocol`, `protocol_fn` | Their type and protocol ids are dense per-VM numbers with no meaning in another process (`docs/PROTOCOLS.md` §0). |
| `db_connection`, `db_write_txn`, `db_read_txn` | Open OS resources. |
| `durable_ref` | An identity into a store; the value half of a durable pair is codec bytes, but a ref inside a value is `:unserializable` (`docs/DB.md` §9). |
| `nextomic_conn`, `nextomic_db`, `nextomic_entity` | Process-local: a Nextomic connection, the db-values taken from it and the entities read through them name a `Conn` the VM owns (`docs/NEXTOMIC.md` §6, §8). |

Encoding any of these returns `error.UnserializableKind`, and decoding
a kind byte that names one returns the same error; a byte that names no
kind (the reserved immediates 8..15, the reserved heap bytes, the
runtime-private sentinels 64 and up) is `InvalidKindByte`. No silent
stubs, no lossy round-trips.

---

### 4. Round-trip invariant (formal)

For every Value `v` in the v1 Serializable set (§1 "In"):

```
(= v (decode(encode(v))))                           — structural equality
(= (hash v) (hash (decode(encode(v)))))             — hash preservation
(encode v) == (encode (decode(encode(v))))          — byte-stable re-encode
                                                      for canonical-order kinds
                                                      (scalars, strings, bignums,
                                                      vectors, lists, typed
                                                      vectors). NOT for map/set
                                                      per §2.5.
```

This is **PLAN §20.2 gate test #5** — exercised on 10k+ randomized
values in `test/prop/codec.zig`.

---

### 5. Public API

```zig
pub const CodecError = error{
    UnserializableKind, // a kind outside §1, or nesting past max_depth (encode)
    TruncatedInput,     // the input ends mid-value, or a count exceeds what remains
    TrailingBytes,      // a whole value, then more bytes
    InvalidVersion,     // envelope other than [1, 0]
    InvalidKindByte,    // a byte that names no kind
    InvalidLeb128,      // a LEB128 past u64
    InvalidCharScalar,  // a surrogate or a scalar past 0x10FFFF
    MalformedPayload,   // a bad per-kind field, a count that disagrees
                        // with the distinct entries, nesting past max_depth
};

pub const max_depth: u32 = 4096;

pub fn encode(
    allocator: std.mem.Allocator,
    interner: *const Interner,
    v: Value,
) (CodecError || std.mem.Allocator.Error)![]u8;

pub fn decode(
    heap: *Heap,
    interner: *Interner,
    bytes: []const u8,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) DecodeError!Value; // CodecError, allocation and interning errors
```

**`encode`** walks the Value graph (recursively for containers),
appending bytes to a growing buffer via the supplied allocator.
Returns the owned byte slice; caller frees.

**`decode`** consumes `bytes` completely; any trailing input
triggers `error.TrailingBytes`. Takes `*Heap` (for allocating
strings / bignums / collections), `*Interner` (for re-interning
keywords / symbols), and hash/eq callbacks (for reconstructing
maps/sets via `champ.mapAssoc` / `setConj`).

Neither function mutates the input or any existing Value — both
are pure producers.

---

### 6. Callers

`src/db.zig` (durable refs), `src/stdlib.zig` (`db/scan`,
`db/reduce-tree`) and `src/nextomic/datom.zig` (the transaction log)
call `encode` and `decode`; the codec imports only the value layer and
the collection modules it walks.

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
- Surrogate char rejection.
- Every kind byte outside §1: `UnserializableKind` for a kind,
  `InvalidKindByte` for a byte that names none.
- `UnserializableKind` on encoding a transient wrapper.
- Hostile lengths and counts (§2.1): a string, keyword or symbol
  length near 2^64, a bignum, typed-vector, list, vector, map or set
  count past the input: `TruncatedInput`, with nothing allocated.
- Depth (§2.7): a value exactly `max_depth` deep round-trips, one
  level more is `UnserializableKind`; 200 000 levels of input is
  `MalformedPayload`.
- Canonicalization policies (§2.6): bignum with trailing zeros
  round-trips to a fixnum; a map or set with a duplicate in its byte
  input is `MalformedPayload`.

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

**C5. Hostile structure**: 500 inputs built to attack the bounds:
LEB128 lengths and counts near 2^64 or past the input behind runs of
nested containers, some past `max_depth`. Each ends in a typed error
(never `OutOfMemory`), and a failed decode allocates no more than the
nesting it read.

`test/prop/typed_vector.zig` T1 is the typed-vector round trip
(both element types, lengths 0, 1, 31, 32, 33 and 1000, equality,
hash and byte-stable re-encode).

Together C1+C3 deliver the PLAN §20.2 gate test #5 receipt. C2
strengthens the invariant for canonical-order kinds. C4 is a
general robustness property against malformed input.

---

### 8. Deferred (explicitly)

- **Cross-process byte-canonicality** for maps and sets (sorted
  keys). Would be a minor version bump.
- **Schema-aware encoders** that skip redundant kind tags for
  homogeneous containers.
- **Streaming encoder / decoder** (`*std.Io.Writer` / `*std.Io.Reader`
  variants). Encode and decode are fully buffered.
- **Byte-vector serialization.** The kind has no implementation.
  A durable ref inside a value is `:unserializable` by design
  (§3).
- **Versioned compact bignum encoding.** Current limbs-in-bytes
  format is simple but not maximally compact for small bignums
  (which are rare by canonicalization).
- **Emdb integration** (`src/db.zig`) — codec bytes are the value
  half of durable key-value pairs; `docs/DB.md`.

---

### 9. Stability

The v1 format is the on-disk format of every durable value and the
Nextomic transaction log, so it is **frozen**: a build reads what an
earlier build wrote. The kind bytes are the `Kind` numbers of
`docs/VALUE.md` §2, which are never renumbered (a retired kind leaves a
reserved gap). Any byte-level change bumps the major or minor version
in the envelope.
