## VALUE.md — Runtime Value Layer

The physical layout of the runtime `Value` and the table of kinds.
`src/value.zig` is the implementation. PLAN §23 decision 1 freezes the
shape (a 16-byte tagged cell, not NaN-boxed); every bit assignment here
is frozen, and a change is a PLAN amendment. The heap block behind a
heap kind is `docs/HEAP.md`; equality and hashing are
`docs/SEMANTICS.md` §2 and §3.

---

### 1. Value — the 16-byte tagged cell

`Value` is an `extern struct { tag: u64, payload: u64 }`: 16 bytes, a
stable layout with no reordering or padding, one 128-bit register on
NEON and SSE.

#### 1.1 Tag word bit layout (little-endian)

| Bits | Field | Contents |
|---|---|---|
| `0..7` | `kind: u8` | The primary discriminator (§2) |
| `8..15` | reserved | 0 |
| `16..31` | `subkind: u16` | The sub-type within a heap kind (§2.2); 0 for immediates |
| `32..63` | list-view offset | For `kind = list` and `subkind = 2` (a vector view), the index of the view's first element in its vector (`docs/LIST.md` §1); 0 otherwise |

`Value.kind()` and `.subkind()` read the fields by shift. Metadata and
the cached hash of a heap object live in its header (`docs/HEAP.md`
§1), not in the tag. Two views of one vector at different offsets
differ in the tag, so `identical?` tells them apart.

#### 1.2 Payload word interpretation

Determined by `kind` (§2). The payload is a plain `u64`; each accessor
(`asFixnum`, `asFloat`, `asChar`, `asKeywordId`, `asSymbolId`,
`Heap.asHeapHeader`) reinterprets it as signed integer, float bits,
scalar, intern id or pointer.

The all-zero Value is `nil`, so zero-filled memory (a fresh heap body,
a grown stack) holds `nil` without initialization.

---

### 2. Kind discriminator

Kind numbers are frozen: the VM switches on them and the codec writes
them as wire tags (`docs/CODEC.md` §9). A kind number is never reused
or renumbered; a retired kind leaves a reserved gap. `Kind.isImmediate`
is `kind < 16`, `Kind.isHeap` is `16 <= kind < 64`. Values 8–15 are
reserved for immediates, 41–63 for heap kinds, 64 and above for
runtime-private sentinels (§2.3).

#### 2.1 Immediates (the payload is the value)

| # | `kind` | Payload |
|---|---|---|
| 0 | `nil` | 0 |
| 1 | `false_` | 0 |
| 2 | `true_` | 0 |
| 3 | `char` | A Unicode scalar (`u21`), zero-extended. Surrogates (D800–DFFF) and values above 10FFFF are rejected at construction |
| 4 | `fixnum` | An i48 integer, sign-extended to i64: `fixnum_min = -(2^47)` to `fixnum_max = 2^47 - 1`. An integer outside that range is a `bignum` (SEMANTICS §2.2) |
| 5 | `float` | The f64 bits. Every NaN is stored as the canonical quiet NaN `0x7FF8000000000000`; `-0.0` is stored as itself |
| 6 | `keyword` | The keyword's intern id (`u32`, `docs/INTERN.md`) |
| 7 | `symbol` | The symbol's intern id (`u32`) |

Because NaN is canonical on every entry path (the constructor, codec
decode, arithmetic), `(= nan nan)` is true and hashes agree. `-0.0` and
`+0.0` differ in bits, so `identical?` distinguishes them while `=` and
`hash` do not (SEMANTICS §2.2, §3.3).

#### 2.2 Heap kinds (the payload is a pointer)

For every heap kind except the pointer kinds (`var_`, `native_fn`, the
three db handles) the payload is a 16-byte-aligned `*HeapHeader`
(`docs/HEAP.md`); `Heap.isBlockKind` names the block kinds.

| # | `kind` | What it is | Subkinds and notes |
|---|---|---|---|
| 16 | `string` | UTF-8 string | 1 = heap string, the only one; 0 (inline) and 2 (zero-copy slice) are reserved (`docs/STRING.md`) |
| 17 | `bignum` | Integer outside the fixnum range (`docs/BIGNUM.md`) | 0 = limbs in the body |
| 18 | `persistent_map` | Map | 0 = array-map (up to 8 entries inline), 1 = CHAMP root. Interior and collision nodes are blocks of this kind that no Value points at; they carry no subkind (`docs/CHAMP.md` §3) |
| 19 | `persistent_set` | Set | As for the map: 0 = array-set, 1 = CHAMP root |
| 20 | `persistent_vector` | 32-way persistent vector | 1 = root. Interior, leaf and tail nodes are blocks of this kind that no Value points at (`docs/VECTOR.md` §2) |
| 21 | `list` | Immutable list | 0 = cons cell, 1 = empty list (each a fresh block, not a shared singleton), 2 = vector view: the body is the vector, the offset is in tag bits 32..63 (`docs/LIST.md` §1) |
| 22 | `byte_vector` | Reserved: never constructed | |
| 23 | `typed_vector` | Homogeneous unboxed numeric vector (`docs/TYPED_VECTOR.md`) | 1 = i64, 3 = f64 (also stored in the body); 0 (i32) and 2 (f32) are reserved |
| 24 | `function` | Closure: routine plus upvalue cells (`docs/VM.md` §6) | |
| 25 | `var_` | Namespace Var | The payload is a raw `*Var` in the VM's runtime arena, not a block: Vars are immortal and the collector reaches their contents through the namespaces (`docs/GC.md` §3) |
| 26 | `durable_ref` | Durable ref: store id, tree, key bytes (`docs/DB.md`) | |
| 27 | `transient` | Mutable wrapper over a persistent collection | 0 = map, 1 = set, 2 = vector (`docs/TRANSIENT.md` §2) |
| 28 | `error_` | Reserved: never constructed | |
| 29 | `meta_symbol` | Reserved: never constructed | Symbols carry no metadata (SEMANTICS §7) |
| 30 | `native_fn` | Host function | The payload points at a static `NativeFn` descriptor, not a block |
| 31 | `db_connection` | emdb connection handle | Payload: a VM-owned `*db.Connection`, not a block |
| 32 | `db_write_txn` | Write transaction handle | Payload: a VM-owned handle, not a block; invalid after commit or abort |
| 33 | `db_read_txn` | Read transaction handle | Payload: a VM-owned handle, not a block |
| 34 | `atom` | In-memory mutable cell (`docs/ATOM.md`) | |
| 35 | `record` | `defrecord` instance: type id plus field map (`docs/PROTOCOLS.md` §2.1) | |
| 36 | `protocol` | Protocol object (`docs/PROTOCOLS.md` §2.2) | |
| 37 | `protocol_fn` | Protocol method dispatcher (`docs/PROTOCOLS.md` §2.3) | |
| 38 | `nextomic_conn` | Nextomic connection (`docs/NEXTOMIC.md` §8) | The block holds a VM-owned connection pointer and the path |
| 39 | `nextomic_db` | Nextomic db-value (`docs/NEXTOMIC.md` §4) | Connection, basis and mode, inline |
| 40 | `nextomic_entity` | Nextomic lazy entity (`docs/NEXTOMIC.md` §6) | The db-value box, the eid and the map of its last full read |

The equality category and hash domain of every kind are SEMANTICS
§3.3; what each block's trace walks is `docs/GC.md` §5; which kinds
the codec writes is `docs/CODEC.md`.

#### 2.3 Sentinels (runtime-private)

| # | Sentinel | Use |
|---|---|---|
| 64 | `unbound` | Reserved: never constructed. A Var with no root has `bound = false` and a nil root; loading it raises `:unbound-var` (`docs/VM.md` §13) |
| 66 | `cell_internal` | A slot whose binding is boxed: the payload is the `*HeapHeader` of an upvalue-cell block of this kind (`docs/VM.md` §6). The compiler's scope records that the slot holds a cell, so user code never reads one; the collector traces the block through the VM |

Kind 65 is a reserved gap. A sentinel never reaches user code. `=` on
one compares bits; hashing one panics.

---

### 3. Canonical constructors

Every immediate has one constructor in `src/value.zig`, which enforces
§2.1 before the Value exists:

| Constructor | Result |
|---|---|
| `nilValue()` | `nil` |
| `fromBool(b)` | `true_` or `false_` |
| `fromChar(scalar: u21) ?Value` | null on a surrogate or a value above 10FFFF |
| `fromFixnum(n: i64) ?Value` | null outside `[fixnum_min, fixnum_max]` (`isFixnumRange`); the caller builds a bignum (`bignum.fromI64`) |
| `fromFloat(f: f64) Value` | infallible; canonicalizes NaN |
| `fromKeywordId(id: u32)`, `fromSymbolId(id: u32)` | wrap an id from the interner, which the constructor does not validate |
| `fromNativeFnPtr(descriptor)` | a `native_fn` over a static descriptor |

A nullable result makes the caller handle the out-of-range case; a
panic would hide the range check from the type system.

A heap-kind Value is built by its kind's module, which allocates the
block and packs kind, subkind and pointer (`Heap.valueFromHeader`, or
the module's own `valueFrom` where a subkind or view offset is set).
Nothing else writes a tag.

The predicates are `isNil`, `isBool`, `isChar`, `isFixnum`, `isFloat`,
`isKeyword`, `isSymbol`, and `isTruthy` / `isFalsy` (only `nil` and
`false` are falsy: kinds 0 and 1; SEMANTICS §1).

---

### 4. HeapHeader

The header in front of every heap block, its layout and its bits are
`docs/HEAP.md` §1 and §4.

### 5. GC bits

The mark byte's bits are `docs/HEAP.md` §4; the collector is
`docs/GC.md`.

---

### 6. Equality and hash obligations

For every `x` and `y`:

```
(identical? x y) ⇒ (= x y)
(= x y)          ⇒ (hash x) = (hash y)
```

`identical?` is `Value.identicalTo`: bit equality of the 16 bytes, so
for a heap kind it is pointer identity (and, for a list view, the same
offset). `=` and `hash` over any Value are `dispatch.equal` and
`dispatch.hashValue`; the immediates go to `Value.equalImmediate` (bit
equality, with `-0.0 = +0.0`) and `Value.hashImmediate`. The rules and
the kind table are SEMANTICS §2 and §3.3. `test/prop/primitive.zig`
checks both implications over randomized immediates (P1–P7); each heap
kind's property file (`test/prop/string.zig`, `list.zig`, `vector.zig`,
`champ.zig`, ...) checks them for that kind.

### 7. Elsewhere

Per-kind body layouts are in each kind's doc; the wire format is
`docs/CODEC.md`; the collector is `docs/GC.md`.
