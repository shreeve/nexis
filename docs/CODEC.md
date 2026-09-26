## CODEC.md — Durable Wire Format

Authoritative wire-format and API contract for `src/codec.zig`, and
the one table of which kinds serialize (§3). Derivative from PLAN §23
#12 (metadata never affects equality) and #25 (serialization scope),
`docs/SEMANTICS.md` (numeric canonical form, hash invariants) and
`docs/VALUE.md` §2 (kind numbers). Those win on conflict.

Codec bytes are the value half of every `db/*` entry and of the
Nextomic transaction log: bytes one process writes, another reads, so
the format is frozen (§9).

---

### 1. Scope

**In.** The data kinds `nil`, `false_`, `true_`, `char`, `fixnum`,
`float`, `keyword`, `symbol`, `string`, `bignum`, `list`,
`persistent_vector`, `persistent_map`, `persistent_set` and
`typed_vector`, and `sorted_map` and `sorted_set` in the natural order
(§2.8), nested to any depth (§2.7).
`encode: Value → []u8`, `decode: []u8 → Value`, behind a version
envelope, with the round-trip laws of §4.

**Out.**
- Every other kind (§3): identity-valued, mutable or process-local.
- **Metadata.** It never takes part in equality or hash (PLAN §23 #12),
  so encode drops it and decode yields values with no metadata; a
  round trip is still `=`.
- **Cross-process byte-canonical maps and sets.** Encode writes them in
  iteration order (§2.5); a sorted-key encoding would be a minor
  version.
- **Schema-aware compact encoding** that skips the kind byte of
  elements of a homogeneous container, a more compact small-bignum
  form, and streaming (`std.Io.Writer` / `Reader`) variants: encode
  and decode are fully buffered.

---

### 2. Wire format

**Envelope, top level only:**

```
[major: u8 = 1] [minor: u8 = 0] [ValueEncoding]
```

The envelope appears exactly once, at the outermost frame; elements,
keys and values inside a container carry only their per-kind encoding.
A major version marks a breaking change, a minor one a new optional
subformat. The format is 1.0. A new kind byte is additive without a
version change: a reader that predates it refuses the byte as
`InvalidKindByte`, never misreads it.

**Per-kind `ValueEncoding`**, kind byte first (the `Kind` number of
VALUE.md §2):

| Kind | Bytes |
|---|---|
| `nil` (0) | `[0]` |
| `false_` (1) | `[1]` |
| `true_` (2) | `[2]` |
| `char` (3) | `[3] [u32 LE = Unicode scalar]` |
| `fixnum` (4) | `[4] [zigzag LEB128 = the i48 value]` |
| `float` (5) | `[5] [u64 LE = IEEE 754 bits, canonical NaN]` |
| `keyword` (6) | `[6] [unsigned LEB128 len] [name bytes]` |
| `symbol` (7) | `[7] [unsigned LEB128 len] [name bytes]` |
| `string` (16) | `[16] [unsigned LEB128 len] [bytes]` |
| `bignum` (17) | `[17] [negative: u8 ∈ {0,1}] [unsigned LEB128 limb_count] [u64 LE × limb_count]` |
| `persistent_map` (18) | `[18] [unsigned LEB128 count] [(key, value) × count]` |
| `persistent_set` (19) | `[19] [unsigned LEB128 count] [element × count]` |
| `persistent_vector` (20) | `[20] [unsigned LEB128 count] [element × count]` |
| `list` (21) | `[21] [unsigned LEB128 count] [element × count]` |
| `typed_vector` (23) | `[23] [elem: u8 ∈ {1 = i64, 3 = f64}] [unsigned LEB128 count] [u64 LE × count]`: i64 as two's-complement bits, f64 as canonical IEEE bits (`docs/TYPED_VECTOR.md` §4) |
| `sorted_map` (41) | `[41] [unsigned LEB128 count] [(key, value) × count]`, keys ascending (§2.8) |
| `sorted_set` (42) | `[42] [unsigned LEB128 count] [element × count]`, ascending (§2.8) |

#### 2.1 Varints and bounds

- **Unsigned LEB128** for every length and count.
- **ZigZag LEB128** for fixnums: small integers take 1–2 bytes, the
  widest i48 eight. A decoded value outside i48 is `MalformedPayload`.
- **Fixed little-endian** for floats and chars (fixed-size inputs),
  bignum limbs (canonical bignums are beyond i48, BIGNUM.md §1) and
  typed-vector elements (eight bytes each in memory too). A
  typed-vector element tag other than 1 or 3 is `MalformedPayload`.
- **Every length and count is bounded by the input before anything is
  allocated for it.** Decode compares a LEB128 value with the bytes
  that remain, never adds it to the cursor: each string byte and each
  list, vector or set element takes at least one byte, each map entry
  two, each limb or typed-vector element eight. A count past what
  remains is `TruncatedInput`, never an overflow or an allocation
  sized by the count. The tenth byte of a LEB128 may carry only bit
  63; more is `InvalidLeb128`. Overlong encodings (`80 00` for 0) name
  the same number and are accepted; encode never writes them.

#### 2.2 Keyword, symbol and string bytes

Length-prefixed raw bytes of the interned name or the string body.
The codec does not validate UTF-8 on either side (`docs/STRING.md`
§2, invariant 4): a runtime-built string or name may hold any bytes, and
rejecting them would break the round trip. Decode re-interns keyword
and symbol names through the supplied `*Interner`; the intern id may
differ from the writer's, and equality holds because ids resolve to
the same bytes.

#### 2.3 Bignum sign byte

Strictly `0` (non-negative) or `1` (negative); any other byte is
`MalformedPayload`.

#### 2.4 Floats

Encode normalizes NaN to the canonical bits `0x7FF8000000000000`
(`hash.canonicalizeFloat`); decode re-canonicalizes any NaN through
`value.fromFloat`. `-0.0` is kept bit-exact: `identical?` tells it
from `+0.0` (SEMANTICS.md §2.2).

#### 2.5 Map and set order

Maps and sets are written in iteration order. Decode yields an equal
collection, but two equal maps built in different orders may encode
to different bytes: the round trip holds, a canonical byte form for
content addressing does not.

#### 2.6 Decode leniency

Decode accepts input that is structurally valid but not canonical:

- A bignum with zero magnitude, trailing zero limbs or a magnitude in
  fixnum range is canonicalized by `bignum.fromLimbs`, so it may
  decode to a fixnum.
- Any NaN bit pattern decodes to the canonical NaN.

A map or set whose distinct decoded entries fall short of its count
is `MalformedPayload`: encode never writes a duplicate, so a corrupt
file never decodes silently to different data. Encode always writes
the canonical form.

#### 2.7 Nesting depth

Nesting is unbounded. Encode and decode each walk containers with an
explicit stack of open containers on the heap, never with native
recursion, so a value nested a million levels deep round-trips on any
thread's stack, and every value written reads back. Decode's stack
holds one frame per open container, and each frame took at least two
bytes of input, so it is bounded by the input's size like everything
else decode allocates.

Decode memory is bounded by what the input holds, whatever its counts
claim. A count larger than the bytes left could encode is
`TruncatedInput` before anything is read for it. The elements of every
list and vector being decoded share one scratch stack, which grows by
one per element actually decoded: nested headers that each claim the
rest of the input cost nothing until the input runs out.

#### 2.8 Sorted maps and sets

A sorted map or set in the natural order (`docs/SORTED.md` §6) is
written in ascending order, so its bytes are canonical: two equal
natural-order collections encode alike, and a re-encode is
byte-stable. Decode checks that each key orders strictly after the one
before it, then builds the balanced tree bottom-up in O(n); keys out
of order, repeated, or with no natural order between them are
`MalformedPayload`. A collection of one entry holds any key, since
nothing is compared. A sorted collection with a comparator of its own
is `UnserializableKind`: the comparator is code.

---

### 3. Serializability by kind

| Kind (number) | Serializes | Why not |
|---|---|---|
| `nil` `false_` `true_` `char` `fixnum` `float` `keyword` `symbol` (0–7) | yes | |
| `string` (16), `bignum` (17), `persistent_map` (18), `persistent_set` (19), `persistent_vector` (20), `list` (21), `typed_vector` (23) | yes | |
| `sorted_map` (41), `sorted_set` (42) | in the natural order | A comparator of its own is code (§2.8). |
| `function` (24), `native_fn` (30) | no | Code, upvalues and VM state are process-local. |
| `var_` (25) | no | An identity with process-local mutation; store its value instead. |
| `durable_ref` (26) | no | A ref names a connection only its own process has (`docs/DB.md` §9). |
| `transient` (27) | no | Mutable by definition; `persistent!` first. |
| `db_connection` (31), `db_write_txn` (32), `db_read_txn` (33) | no | Open OS resources. |
| `atom` (34) | no | A mutable identity (`docs/ATOM.md` §6). |
| `record` (35), `protocol` (36), `protocol_fn` (37) | no | Type and protocol ids are dense per-VM numbers (`docs/PROTOCOLS.md` §0). |
| `nextomic_conn` (38), `nextomic_db` (39), `nextomic_entity` (40) | no | They name a Nextomic connection the VM owns (`docs/NEXTOMIC.md` §6). |
| `byte_vector` (22), `error_` (28), `meta_symbol` (29) | no | Reserved numbers; never constructed. |

Encoding any kind marked no is `UnserializableKind`. Decoding a kind byte that names a heap kind
outside the set (every "no" row above) is `UnserializableKind` too;
a byte that names no kind (the reserved immediates 8–15, the reserved
heap bytes 43–63, the runtime-private sentinels 64 and up) is
`InvalidKindByte`. No silent stubs, no lossy round trips.

**At the language level** (`db.failureName`, `docs/DB.md` §8)
`UnserializableKind` is `:unserializable`, on encode and on decode
alike, and every other codec error — hostile lengths and counts,
a bad envelope, trailing bytes — is
`:codec-failed`.

---

### 4. Round-trip laws

For every value `v` of the serializable set:

```
(= v (decode (encode v)))                     structural equality
(= (hash v) (hash (decode (encode v))))       hash preservation
(encode v) == (encode (decode (encode v)))    byte-stable re-encode, for every kind but the hash map and set (§2.5)
```

This is the codec gate property, run by `test/prop/codec.zig` (§7).

---

### 5. Public API

| Name | Contract |
|---|---|
| `encode(allocator, *const Interner, Value) (CodecError \|\| Allocator.Error)![]u8` | The owned bytes of `v`; the caller frees. |
| `decode(*Heap, *Interner, bytes, elementHash, elementEq) DecodeError!Value` | Consumes `bytes` completely. Maps and sets are rebuilt with the supplied hash and equality, which must be `dispatch.hashValue` / `dispatch.equal` or agree with them (`docs/DB.md` §5). |
| `version_major = 1`, `version_minor = 0` | §2. |

`DecodeError` is `CodecError` plus allocation and interning errors.
Neither function mutates its input or any existing value.

| `CodecError` | Meaning |
|---|---|
| `UnserializableKind` | A kind outside the set (§3), on encode or as a decoded kind byte. |
| `TruncatedInput` | The input ends mid-value, or a length or count asks for more than remains. |
| `TrailingBytes` | A whole value, then more bytes. |
| `InvalidVersion` | An envelope other than `[1, 0]`. |
| `InvalidKindByte` | A byte that names no kind. |
| `InvalidLeb128` | A LEB128 past u64. |
| `InvalidCharScalar` | A surrogate or a scalar past `0x10FFFF`. |
| `MalformedPayload` | Input no encoder writes: a bad sign byte or element tag, a fixnum outside i48, a count that disagrees with the distinct entries. |

---

### 6. Callers

`src/db.zig` (`put` / `get`), `src/stdlib.zig` (`db/scan`,
`db/reduce-tree`) and `src/nextomic/datom.zig` (the transaction log)
call `encode` and `decode`; the codec imports only the value layer and
the collection modules it walks.

---

### 7. Testing

The inline tests in `src/codec.zig` cover each kind's round trip (a
sorted map and set among them, with the refusal of a comparator and of
keys out of order), the
envelope, truncation, trailing bytes, malformed LEB128, surrogate
chars, every one of the 256 kind bytes outside the set
(`UnserializableKind` or `InvalidKindByte` as §3 says), a transient on
encode, hostile lengths and counts near 2^64 (`TruncatedInput` with
nothing allocated), a value 200 000 levels deep round-tripping byte
for byte, 200 000 levels of input of each container kind decoding,
and the leniency of §2.6.

`test/prop/sorted.zig` P8 round-trips random natural-order sorted maps
and sets, byte-stable. `test/prop/codec.zig`: **C1** 100 000 random values of every
serializable kind, nested up to depth 4, round-trip equal with equal
hashes; **C2** re-encode is byte-equal for every kind but map and set;
**C3** a transient is `UnserializableKind`; **C4** 1 000 random byte
slices decode to a value or a `CodecError`, never a crash; **C5** 500
hostile headers (lengths and counts near 2^64 or past the input,
under nesting thousands of levels deep) end in a typed error or a
value, never `OutOfMemory`, allocating no more than the nesting read. `test/prop/typed_vector.zig`
T1 is the typed-vector round trip.

---

### 9. Stability

The format is the on-disk form of every durable value and the
Nextomic transaction log, so it is frozen: a build reads what an
earlier build wrote. The kind bytes are the `Kind` numbers of
`docs/VALUE.md` §2, which are never renumbered; a retired kind leaves
a reserved gap. Any byte-level change bumps the major or minor version
in the envelope.
