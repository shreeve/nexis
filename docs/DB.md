## DB.md — Durable identities & emdb integration (Phase 1)

**Status**: Phase 1 deliverable. Authoritative contract for
`src/db.zig`. Derivative from `PLAN.md` §15 (durable identities,
connection model, transactions, codec boundary) + §20.2 gate test
#6 (emdb round-trip) + `docs/CODEC.md` (value-bytes serialization)
+ `docs/VALUE.md` §2.2 (kind 26 reserved for `durable_ref`). Those
documents win on conflict. Reviewed peer-AI turn 23.

This commit closes the last pending Phase 1 gate test (#6) and
completes the §20.2 gate scorecard to **8/8 shipped**. Codec bytes
(landed in commit `f745604`) are the value half of every
durable-ref round-trip; this commit ships the emdb bridge + the
`durable_ref` heap Value kind to complete the picture.

Phase 4 per PLAN §21 schedules richer surface area (lexical
transactions via `with-tx` macros, `as-of` snapshots, cursors, the
stdlib `db/...` namespace). Phase 1's job is the Zig-level runtime
primitives + the gate #6 receipt.

---

### 1. Scope

**In (v1):**
- `Connection` — wrapper around `emdb.Env` with a stable
  `store_id: u128` and an `*Interner` pointer for codec
  integration.
- `Connection.open(allocator, heap, interner, path, options)`,
  `Connection.close()`.
- `WriteTxn` / `ReadTxn` — thin wrappers around `emdb.Txn` with
  nexis-typed errors and codec integration.
- `beginWrite()` / `beginRead()` / `commit()` / `abort()`.
- `put(txn, tree_name, key_bytes, value)` — opaque `key_bytes`,
  Value `value` encoded via `src/codec.zig`.
- `get(txn, tree_name, key_bytes) !?Value` — decode via codec.
- `del(txn, tree_name, key_bytes) !bool`.
- `ref(heap, conn, tree_name, key_bytes) !Value` — construct a
  `durable_ref` heap Value.
- `putRef` / `getRef` / `delRef` convenience wrappers that resolve
  `tree_name` + `key_bytes` from the ref body.
- Per-kind dispatch integration: hash = xxHash3-32 over identity
  triple; equality = byte-for-byte on the triple; GC trace = no-op
  (per §7).
- Gate #6 property test: 10k values × multiple named trees ×
  reopen-connection readback.

**Out (deferred to later commits / phases):**
- `alter!` (derivable from get+put; stdlib macro in Phase 3).
- `as-of` / snapshots / historical reads (PLAN §15.7).
- Cursors / `reduce-tree` / `scan` (PLAN §15.8) — Phase 3 tooling.
- Language-surface `(with-tx ...)` macro — Phase 3 stdlib.
- emdb file-UUID integration (§2 v1 interim workaround).
- Multi-isolate / multi-process durability semantics — v2+.
- Performance benchmarking — Phase 6 per PLAN §19.

---

### 2. `store_id` derivation (v1 interim)

PLAN §15.1: "A connection has a stable `store-id: u128` derived
from the file UUID written in emdb's meta page."

**emdb's v0.8 MetaPage does NOT carry a file UUID** (fields:
magic, version, mapAddr, mapSize, freeTree, mainTree, txnId,
lastPgno, canary, pageSize — no UUID slot). Adding one is an emdb
spec change; this commit defers that to a later coordinated
emdb+nexis amendment.

**v1 interim** (peer-AI turn 23): derive `store_id` as:

```
store_id = xxHash3-128(realpath(file))
```

where `realpath` is the canonicalized absolute path bytes. This
is:
- **stable within a process / session for an unmoved file**;
- **NOT stable across rename / move** of the file;
- **NOT a true store UUID** — two files with identical content
  but different paths have different store_ids;
- **sufficient for gate #6** (within-process round-trip).

When emdb ships a real file UUID (targeted Phase 4 or earlier if
expedient), the envelope version in CODEC.md §2 bumps and
`store_id` derivation switches to reading the UUID from the meta
page on `Connection.open`. `Connection` exposes `storeId() u128`
as a read-only accessor so downstream code doesn't hardwire the
derivation.

---

### 3. `Connection` shape

```zig
pub const Connection = struct {
    // Non-owning: caller supplies these and guarantees their
    // lifetimes meet or exceed the Connection's.
    allocator: std.mem.Allocator,
    heap: *Heap,
    interner: *Interner,

    // Owning (closed by Connection.close).
    env: emdb.Env,
    store_id_lo: u64,
    store_id_hi: u64,
    // Canonicalized absolute path, owned. Freed in close().
    path_owned: [:0]u8,
};
```

**`Connection` is NOT a runtime heap-managed Value.** It's a plain
Zig struct allocated on the caller's allocator. Multiple
durable-refs may point to the same Connection; the Connection
itself is not reference-counted. Caller owns the lifetime via
explicit `close()`.

**Metadata attachability**: not applicable. Connections are not
Values.

---

### 4. `durable_ref` heap kind (VALUE.md §2.2 kind 26)

Per PLAN §15.2 and SEMANTICS.md §2.6 (kind-local equality,
identity-triple hash).

#### 4.1 Body layout

```zig
const DurableRefBody = extern struct {
    /// Operational pointer to the Connection that produced this
    /// ref. NON-IDENTITY — not hashed, not compared in equality,
    /// not GC-traced. May be stale (closed connection) or
    /// cross-store if the ref was reconstructed from bytes (codec
    /// decode) without a matching connection available.
    conn: ?*Connection,

    /// First 64 bits of the u128 store_id.
    store_id_lo: u64,
    /// Upper 64 bits of the u128 store_id.
    store_id_hi: u64,

    /// Length of the tree name (UTF-8 bytes) that follows the
    /// header. The tree name is the emdb named-subtree identifier.
    tree_name_len: u32,
    /// Length of the key bytes that follow the tree name.
    key_bytes_len: u32,

    // Body total = 32 bytes header + tree_name_len + key_bytes_len.
    // Inline byte storage (not a pointer elsewhere) so the ref is
    // self-contained and codec-portable without ancillary heap
    // walks.
};
```

**`conn: ?*Connection` is advisory**, per peer-AI turn 23:
- NOT part of identity — equality and hash ignore it.
- NOT GC-traced — `*Connection` is not a heap Value.
- MAY be `null` for refs reconstructed from bytes without a live
  connection context (codec decode does not resolve a Connection
  pointer; see §8).
- MAY be stale if the Connection was closed after ref construction.
- Set by `ref(heap, conn, ...)` constructors; left `null` by codec
  decode.

#### 4.2 Subkind

Subkind byte is unused in v1 (single canonical durable-ref shape).
Reserved for future variants (e.g., weak refs, snapshot-bound
refs). Always `0`.

---

### 5. API surface

```zig
pub const DbError = error{
    /// Connection operation attempted on a closed or null conn.
    ConnectionUnavailable,
    /// Ref's store_id doesn't match the Connection passed in.
    StoreMismatch,
    /// Tree name is empty.
    InvalidTreeName,
    /// Key is empty.
    InvalidKey,
    /// Transaction kind mismatch (write op in read txn, etc.).
    TransactionKindMismatch,
    // plus propagated: emdb.Error, Allocator.Error, CodecError,
    // InternError, etc.
};

pub const Connection = struct { ... };

pub fn open(
    allocator: std.mem.Allocator,
    heap: *Heap,
    interner: *Interner,
    path: [*:0]const u8,
    options: emdb.EnvOptions,
) !Connection;

pub fn close(self: *Connection) void;
pub fn storeId(self: *const Connection) u128;

// ---- Transaction wrappers ----

pub const WriteTxn = struct { conn: *Connection, inner: *emdb.Txn };
pub const ReadTxn = struct { conn: *Connection, inner: *emdb.Txn };

pub fn beginWrite(conn: *Connection) !WriteTxn;
pub fn beginRead(conn: *Connection) !ReadTxn;

pub fn commit(txn: *WriteTxn) !void;
pub fn abortWrite(txn: *WriteTxn) void;
pub fn abortRead(txn: *ReadTxn) void;

// ---- Tree-name + key-bytes API (opaque keys) ----
//
// Keys are OPAQUE BYTE SLICES at the Zig runtime layer (peer-AI
// turn 23). They are NOT codec-encoded. Callers supply a byte
// sequence that becomes the emdb key directly. Values are
// codec-encoded on put and codec-decoded on get.

pub fn put(
    txn: *WriteTxn,
    tree_name: []const u8,
    key_bytes: []const u8,
    value: Value,
) !void;

/// `elementHash` / `elementEq` MUST be the authoritative runtime
/// hash and equality for all codec-serializable kinds (production
/// callers pass `&dispatch.hashValue, &dispatch.equal`). See §6.1.
pub fn get(
    txn_read_or_write: anytype,
    tree_name: []const u8,
    key_bytes: []const u8,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !?Value;

pub fn del(
    txn: *WriteTxn,
    tree_name: []const u8,
    key_bytes: []const u8,
) !bool;

// ---- Durable-ref Value construction + ref-based ops ----

pub fn ref(
    heap: *Heap,
    conn: *Connection,
    tree_name: []const u8,
    key_bytes: []const u8,
) !Value;

pub fn refFromBytes(
    heap: *Heap,
    store_id: u128,
    tree_name: []const u8,
    key_bytes: []const u8,
) !Value;

pub fn putRef(txn: *WriteTxn, r: Value, value: Value) !void;
pub fn getRef(
    txn_read_or_write: anytype,
    r: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !?Value;
pub fn delRef(txn: *WriteTxn, r: Value) !bool;

// ---- Identity accessors (for codec + equality) ----

pub fn refStoreId(r: Value) u128;
pub fn refTreeName(r: Value) []const u8;
pub fn refKeyBytes(r: Value) []const u8;
pub fn refConn(r: Value) ?*Connection;
```

---

### 5.1 Why `get` takes hash/eq callbacks

Callers of `get` / `getRef` pass the runtime hash + equality
functions that the codec uses to rebuild decoded collections
(maps, sets, vectors). Production callers pass
`&dispatch.hashValue, &dispatch.equal`. Test code with a
restricted Value alphabet may pass narrower stand-ins.

The callbacks are parameterized (rather than `db.zig` importing
`dispatch.zig` directly) because `dispatch.zig` already imports
`db.zig` to route `.durable_ref` hash / equality arms. Passing
them in keeps the module graph one-way terminal.

**Soundness requirement** (peer-AI turn 24): the callbacks MUST
produce the SAME hash / equality relation as `dispatch.hashValue`
/ `dispatch.equal` for every kind that may appear as a map key or
set element in decoded bytes. A mismatched hash callback silently
mis-places entries in CHAMP-shaped maps (≥9 entries), causing
subsequent dispatch-based lookups to miss present keys. Small
array-maps (≤8 entries) tolerate mismatched callbacks because
they probe purely via equality.

`src/db.zig`'s inline tests use narrow stand-ins (only scalar
values, always array-map-sized collections) precisely because the
soundness requirement above is satisfied trivially when CHAMP
trees never form. `test/prop/db.zig` uses the authoritative
dispatch callbacks and stresses full CHAMP depth through randomized
generation.

### 6. Named-tree discovery

emdb exposes `txn.openTree(name, create)` returning a
transaction-scoped `TreeId`. v1 calls `openTree` **per operation**,
accepting the small lookup cost in exchange for a simpler
implementation:

```zig
// In put/get/del:
const tree_id = try txn.inner.openTree(tree_name, /* create */ true);
try txn.inner.putInTree(tree_id, key_bytes, encoded_value_bytes);
```

Caching `TreeId` per `(connection, tree_name)` pair with
invalidation rules (tree closed, connection closed) is a Phase 6
performance optimization per PLAN §19; not in v1.

Empty tree names (length 0) and empty keys return
`error.InvalidTreeName` / `error.InvalidKey`.

---

### 7. Equality, hash, GC integration

#### 7.1 Equality (SEMANTICS.md §2.6, PLAN §15.2)

Two `durable_ref` Values are `=` iff their **identity triples
match byte-for-byte**:

- `store_id_lo == store_id_lo' AND store_id_hi == store_id_hi'`
- `tree_name_len == tree_name_len' AND tree_name_bytes byteeq`
- `key_bytes_len == key_bytes_len' AND key_bytes byteeq`

The `conn` field is NOT consulted. Two refs reconstructed from
different processes / connections / codec byte sources with
matching identity triples compare equal.

#### 7.2 Hash (SEMANTICS.md §3.2)

```
base = xxHash3-32(
  store_id_lo_bytes_LE ++ store_id_hi_bytes_LE ++
  tree_name_bytes ++
  key_bytes)
```

`dispatch.hashValue` applies the kind-local domain mix
(`mixKindDomain(u64(base), 26)`) on the way out. Same `durable_ref`
identity produces the same hash regardless of `conn` state.

Cached in the HeapHeader's `hash: u32` slot per the standard
cache-if-nonzero pattern.

#### 7.3 GC trace (GC.md §5)

```zig
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    _ = h;
    _ = visitor;
}
```

No heap children. `conn` is a plain pointer to a non-heap-managed
`Connection` struct; GC must not follow it. Tree-name and
key-bytes are inline body bytes, not references. `meta` handled
centrally by the collector.

---

### 8. Failure semantics

Per peer-AI turn 23, pinned explicitly:

| Condition | Behavior |
|---|---|
| `putRef` / `getRef` / `delRef` on ref with `conn == null` | `error.ConnectionUnavailable` |
| `putRef` / `getRef` / `delRef` on ref with `conn.storeId() != r.store_id` | `error.StoreMismatch` |
| Write op in a read transaction | `error.TransactionKindMismatch` |
| Closed connection (double-close) | undefined; caller bug |
| Codec encode / decode error during put / get | propagated `CodecError` |
| emdb-level errors (`KeyTooLarge`, `DatabaseFull`, `TxnAborted`, etc.) | propagated `emdb.Error` |

**Equality and hash are unaffected** by any of the above — the
identity triple is fully defined by the stored bytes, independent
of operational state.

**Re-hydrating a ref** (constructing from bytes without an
available Connection): `refFromBytes(heap, store_id, tree_name,
key_bytes)` returns a ref with `conn = null`. I/O operations
(`putRef`, `getRef`, `delRef`) will return
`error.ConnectionUnavailable` until the ref is "bound" to a live
Connection. The low-level API does not bind refs; callers that
need binding do it at a higher layer (stdlib Phase 3).

---

### 9. Codec integration

`durable_ref` serialization is pinned in PLAN §23 #25 and
CODEC.md §2. The wire form is the identity triple:

```
[26] [unsigned LEB128 tree_name_len] [tree_name_bytes]
     [unsigned LEB128 key_bytes_len] [key_bytes]
     [u64 LE store_id_lo] [u64 LE store_id_hi]
```

This commit DOES NOT add `.durable_ref` to `src/codec.zig`'s
encode/decode arms. That's a follow-on codec amendment. The
reason: codec bytes for durable-ref are exclusively for
**ref-containing values** (e.g., a map whose values are refs),
and the primary use case in Phase 1 is `get(tree, key)` returning
a ref from a stored Value blob. Gate #6 tests direct-ref round-
trip via the `durable_ref` body layout, not via codec-encoded refs
inside other Values.

Adding the codec arm is trivial (~30 LOC); it's explicitly
deferred here so this commit stays focused on the DB bridge. A
follow-up commit can land the codec integration with a small
property-test extension.

---

### 10. Gate #6 property test (PLAN §20.2 test #6)

`test/prop/db.zig` D1:

```
Write 10,000 random Values across 5 named trees. Each tree gets
2,000 entries with deterministic keys. Keys are derived from
trial index + tree index so overlapping-key cases occur across
trees (key "k0" in tree A != key "k0" in tree B unless they were
explicitly put with the same value).

Assertions:
  - Every write succeeds.
  - Every read back yields `dispatch.equal` AND
    `dispatch.hashValue`-equal recovery.
  - Cross-tree independence: key "k0" in tree A vs key "k0" in
    tree B have distinct values when the writer set them distinct.
```

D2: **Reopen-connection readback** (peer-AI turn 23
strengthening). After all writes commit and the Connection is
closed, reopen the same file and read every key back; assert
values match what was written.

D3: `durable_ref` identity triple round-trip via equality + hash
(simpler property — no DB I/O, just ref construction and
comparison).

D4: `ConnectionUnavailable` / `StoreMismatch` error paths.

Together D1 + D2 deliver PLAN §20.2 gate test #6 receipt:
"writing 10k values across N named trees, then reading them back,
yields structural equality for all; named trees are independent."

---

### 11. Module graph

```
src/db.zig
├── @import("std")
├── @import("value")
├── @import("heap")
├── @import("intern")
├── @import("hash")
├── @import("codec")
└── @import("emdb")     // external path dependency per build.zig.zon
```

One-way terminal. `src/dispatch.zig` and `src/gc.zig` gain
`.durable_ref` arms that call back into `db.zig`'s hash / equal /
trace helpers.

---

### 12. Deferred (explicitly)

- Language-surface `(with-tx ...)` macro — PLAN §21 Phase 3.
- `as-of` / snapshots / `db/snapshot-stats` — PLAN §15.7.
- Cursors / `reduce-tree` / `scan` — PLAN §15.8.
- `alter!` — derivable, Phase 3 stdlib macro.
- emdb file-UUID integration — coordinated emdb amendment.
- Multi-process concurrent writes — emdb handles single-writer
  discipline; nexis surface stays single-isolate per PLAN §16.1.
- `.durable_ref` codec encode/decode arms — §9 follow-up.
- `Connection`-level `TreeId` cache — Phase 6 optimization.

---

### 13. Amendment note

This file is new in the commit that lands `src/db.zig`. No
pre-existing doc is replaced. Cross-refs updated in `README.md`
and `HANDOFF.md` §7 (pending-modules checklist).

`docs/VALUE.md` §2.2 row 26 (`durable_ref`) remains as pinned:
"subkind 0 = v1 canonical; reserved 1..15 for future variants."

`docs/SEMANTICS.md` §2.6 and §3.2: `durable_ref` equality /
hash rules are already pinned there; this commit realizes them.
