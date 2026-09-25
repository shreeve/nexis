## DB.md — Durable identities & emdb integration

Authoritative contract for `src/db.zig` and the `db/*` language surface
built on it (the db natives in `src/stdlib.zig`, the `with-tx` family
in `src/stdlib/core.nx`). Derivative from `PLAN.md` §15 (durable
identities, connection model, transactions) and §20.2 gate test #6
(emdb round-trip); values cross the store as `docs/CODEC.md` bytes;
`durable_ref` is kind 26 (`docs/VALUE.md` §2.2). Nextomic, the datom
database on the same engine, is `docs/NEXTOMIC.md`.

---

### 1. Scope

`db.zig` is the key-value bridge to emdb: a `Connection` over one
store file, write and read transactions, `put` / `get` / `del` of
codec-encoded values under opaque byte keys in named trees, and the
`durable_ref` heap kind that names one `(store, tree, key)` slot. The
language surface (§12) adds auto-transaction ref operations,
`with-tx` / `with-read-tx` / `with-snapshot`, `db/alter!` and the eager
tree walks `db/scan` and `db/reduce-tree`.

Multi-process concurrent writes are emdb's single-writer discipline;
the nexis surface is single-isolate (PLAN §16.1).

---

### 2. `store_id` derivation

emdb's meta page carries no file id, so `store_id: u128` comes from
the file's path. `open` resolves the canonical path
(`realPathFileAlloc`) after emdb has opened, and so created, the file;
a platform that cannot resolve one keeps the path as given. The low
64 bits are `hash.hashBytes(path)`; the high 64 bits are xxHash3,
seeded with `hash.seed`, over `"store-id"` followed by the path.

So `x.edb`, `./x.edb` and the absolute spelling name one store (the
inline test "store_id comes from the canonical path" pins it). The id
is stable for an unmoved file and changes when the file is renamed or
moved; two files with equal contents at different paths are different
stores. `storeId()` is the accessor; nothing else depends on the
derivation.

**Parent directories.** emdb creates only the file. `(db/open path)`
creates the missing parent directories first, with the VM's `std.Io`
(or the process-wide single-threaded one when the host gave the VM
none); a failure there is ignored, and emdb's own open then reports
`:db/open-failed`.

---

### 3. `Connection`

A plain Zig struct, not a Value: it holds the `emdb.Env`, the
non-owning allocator, heap and interner the codec needs, the two
`store_id` halves, the owned canonical path, an open flag, a count of
open transactions and the tree-handle cache. The stdlib allocates each
one on the VM's allocator, records it in `vm.db_connections`, and
frees it only at VM teardown, so no address a Value holds is reused
while the VM lives. A `db_connection` Value (kind 31) is a pointer to
it; `db_write_txn` (32) and `db_read_txn` (33) point at a
per-transaction handle.

**Pinned geometry.** `open` overrides the caller's `pageSize` with
`db.page_size` (16 KiB) and `maxNamedTrees` with `db.max_named_trees`
(128). emdb's default page size is the OS page size, and the page
size fixes the key bound and overflow threshold for the life of the
file, so every store carries the same geometry wherever it is
created. An existing file keeps the page size it was created with.

**Tree handles resolve once per connection.** `treeId(txn, name,
create)` looks the name up in the connection's cache before asking
emdb; a `TreeId` is fixed for the life of the environment. emdb keeps
per-transaction tree state, so each transaction carries a bit set and
loads a tree the first time it touches it; later operations on that
tree in the same transaction are a bit test. A tree registered by an
aborted transaction stays registered and reads as empty.

**Cursor values are whole.** An emdb cursor returns a multi-page value
assembled in the transaction's buffer, valid until the next multi-page
read on that transaction; `db/scan` and `db/reduce-tree` decode each
entry before advancing.

**Closing.** `close` closes the env and leaves the struct in place
with the open flag false: a ref, transaction handle or connection
Value that still names it reports the connection closed. A second
`close` does nothing. `close` while a transaction of the connection is
open is refused (`TransactionsOpen`), so no emdb transaction outlives
its env. `shutdown` closes whatever is open, for VM teardown.

**A failed commit aborts.** emdb leaves a transaction whose commit
failed open, holding the write lock; `commit` aborts it before
returning the error, so the transaction is over either way.

---

### 4. `durable_ref` heap kind (VALUE.md §2.2 kind 26)

The body is a 32-byte header — an advisory `conn: ?*Connection`, the
two `store_id` halves, and the tree-name and key lengths as `u32` —
followed inline by the tree-name bytes and then the key bytes. The
subkind is always 0.

The identity is the triple `(store_id, tree_name, key_bytes)`. `conn`
is operational only: not hashed, not compared, not traced. `ref` sets
it to the connection the ref was made on; `refFromBytes` leaves it
null, and I/O through a null-`conn` ref is `ConnectionUnavailable`. A
ref may outlive its connection: its own I/O then reports the
connection closed, but inside a transaction of another connection to
the same store it reads and writes normally (§8).

---

### 5. Zig API

`DbError` is `ConnectionUnavailable`, `StoreMismatch`,
`InvalidTreeName`, `InvalidKey`, `TransactionsOpen`; emdb, codec,
intern and allocator errors propagate unchanged.

| Function | Contract |
|---|---|
| `open(allocator, io, heap, interner, path, options) !Connection` | §2, §3. |
| `close(*Connection) DbError!void` / `shutdown(*Connection) void` | §3. |
| `storeId(*const Connection) u128` | §2. |
| `beginWrite(*Connection) !WriteTxn` / `beginRead(*Connection) !ReadTxn` | `ConnectionUnavailable` on a closed connection. |
| `commit(*WriteTxn) !void` / `abortWrite(*WriteTxn)` / `abortRead(*ReadTxn)` | End the transaction; a failed commit aborts (§3). |
| `treeId(txn, name, create) !?TreeId` | §3; null for an absent tree when `create` is false. |
| `validateTreeName(name) DbError!void` | §6. |
| `put(*WriteTxn, tree, key, value) !void` | Encodes `value` (CODEC.md) under the opaque `key` bytes; creates the tree. |
| `get(txn, tree, key, elementHash, elementEq) !?Value` | Either transaction kind; null when the key or the tree is absent. |
| `del(*WriteTxn, tree, key) !bool` | Whether the key existed. |
| `ref(heap, conn, tree, key) !Value` / `refFromBytes(heap, store_id, tree, key) !Value` | §4. |
| `putRef` / `getRef` / `delRef` | The same through a ref's tree and key, after checking the ref belongs to the transaction's store (§8). |
| `refStoreId` / `refTreeName` / `refKeyBytes` / `refConn` | The ref's fields. |
| `hashHeader` / `refsEqual` / `trace` | §7. |
| `failureName(anyerror) []const u8` | The keyword a failure surfaces as (§8). |

Keys are opaque byte slices, never codec-encoded; values are
codec-encoded on `put` and decoded on `get`.

**`get` takes the hash and equality the codec rebuilds maps and sets
with.** `dispatch.zig` imports `db.zig` for the `.durable_ref` arms,
so `db.zig` cannot import `dispatch.zig`; the caller passes
`&dispatch.hashValue, &dispatch.equal`. Any other pair must agree with
them on every kind that can be a decoded key or element: a mismatched
hash misplaces entries in a CHAMP-shaped map or set (9 or more
entries), and later lookups miss present keys. The inline tests use
narrow stand-ins with scalar values and array-map-sized collections;
`test/prop/db.zig` uses the dispatch pair.

---

### 6. Named trees

A tree name is refused when it is empty or begins `nx/`: Nextomic
keeps its indexes and transaction log in `nx/*` trees
(`docs/NEXTOMIC.md` §2), and a `db/*` write there would bypass every
Nextomic invariant. An empty key is refused too. `validateTreeName` is
public so `db/scan` and `db/reduce-tree` refuse the same names. All of
these are `:db/invalid-key` at the language level.

---

### 7. Equality, hash, GC integration

Equality category and hash domain: SEMANTICS.md §3.3.

#### 7.1 Equality

Two refs are `=` when their triples match byte for byte; `conn` is not
consulted, so refs made on different connections to one store are
equal.

#### 7.2 Hash

64-bit xxHash3, seeded with `hash.seed`, over the `store_id` low and
high halves as little-endian bytes, then the tree-name bytes, then the
key bytes; truncated to `u32` and cached in the header when nonzero.
`dispatch.hashValue` applies the kind's domain on the way out.

#### 7.3 GC trace

None: a ref has no heap children. `conn` points at a non-heap
`Connection`, and the tree name and key are inline bytes (GC.md §5).

---

### 8. Failure semantics

| Condition | Zig error | Keyword |
|---|---|---|
| I/O through a ref whose `conn` is null | `ConnectionUnavailable` | `:db/no-connection` |
| A ref used in a transaction of a different store | `StoreMismatch` | `:db/store-mismatch` |
| A transaction begun on a closed connection | `ConnectionUnavailable` | `:db-closed` (the natives check first) |
| Empty or `nx/` tree name, empty key | `InvalidTreeName` / `InvalidKey` | `:db/invalid-key` |
| `close` with a transaction open | `TransactionsOpen` | `:db/busy` |
| A second `close` | none | none (nil) |
| Encode of a kind with no serialized form (CODEC.md §3) | `UnserializableKind` | `:unserializable` |
| Stored bytes that do not decode | any other `CodecError` | `:codec-failed` |

emdb errors map by `failureName`: `:db/key-too-large`,
`:db/value-too-large`, `:db/max-trees`, `:db/not-found`,
`:db/corrupted` (also a file that is not a store, and a format-version
mismatch), `:db/map-full`, `:db/mmap-failed`, `:db/open-failed`,
`:db/page-size-mismatch`, `:db/busy` (a writer already active, the
environment busy), `:db/txn-aborted`, `:db/read-only`,
`:db/sync-failed`; anything else is `:db-error`. Nextomic shares these
`:db/*` names through the same function.

The natives throw them with `vm.throwKeyword`, so `(catch any e …)`
binds the keyword and, outside any `try`, the throw is uncaught like
every recoverable error. Equality and hash are unaffected by any
failure: the triple is fixed at construction.

**Two connections to one file.** A ref made on one connection is
accepted in a transaction of another connection to the same store.
emdb's writer lock is per file, so a write through the second
connection while the first holds a write transaction waits on a
writer the same single-threaded process holds: it never returns.
Nextomic refuses that case itself (`docs/NEXTOMIC.md` §3); `db/*` does
not.

---

### 9. Codec integration

Values are CODEC.md bytes. A durable ref inside a stored value is
`:unserializable`: the kind is not in the serializable set
(CODEC.md §3).

---

### 10. Tests

`test/prop/db.zig` is PLAN §20.2 gate test #6: D1 writes 10 000 random
values across 5 named trees and reads each back equal with an equal
hash; D2 closes, reopens the file with a fresh heap and interner, and
reads 2 000 values back; D3 checks that the identity triple alone
decides ref equality and hash; D4 writes the same key to every tree
with different values and reads each tree's own back. The inline tests
in `src/db.zig` pin the canonical store id, the pinned geometry, close
refused while a transaction is open, the tree-handle cache,
`ConnectionUnavailable`, `StoreMismatch` and the invalid names. The
language surface runs in `test/integration/eval_pipeline.zig`,
`test/integration/runtime_polish.zig` and `examples/durable-refs.nx`.

---

### 11. Module graph

`db.zig` imports `value`, `heap`, `intern`, `hash`, `codec` and
`emdb`. `dispatch.zig` and `gc.zig` call its hash, equality and trace
helpers at their `.durable_ref` arms; `stdlib.zig` holds the natives;
Nextomic imports it only for `failureName` and the geometry
constants `page_size` and `max_named_trees`: it opens its own
`emdb.Env` with them, keeps raw byte keys and never goes through
`db.zig`'s connections, trees, codec calls or refs.

---

### 12. Language surface

Every native is in the `db` namespace. A ref's tree is a keyword whose
name is the tree name (`:a/b` names tree `a/b`); its key is a keyword,
symbol or string whose name or bytes are the key, so `(db/ref c :t :k)`,
`(db/ref c :t 'k)` and `(db/ref c :t "k")` are equal. Wrong argument
kinds are `:kind-mismatch`, a non-ref where a ref belongs is
`:invalid-durable-ref`, a wrong argument count is `:arity-mismatch`,
and any operation on a closed connection or through a ref of one is
`:db-closed`. Storage and codec failures are §8.

| Form | Arity | Result |
|---|---|---|
| `(db/open path)` | 1 | A connection; creates the file and its parent directories. |
| `(db/close conn)` | 1 | nil; closing twice is nil; with a transaction open, `:db/busy`. |
| `(db/ref conn tree key)` | 3 | A durable ref (§4); prints `#<durable-ref :tree hex:…>`. |
| `(db/ref? x)` | 1 | Whether `x` is a durable ref. |
| `(db/put-key! ref v)` | 2 | nil; one write transaction around one put. |
| `(db/get-key ref)` / `(db/get-key ref default)` | 1–2 | The stored value, or `default` (nil); one read transaction. |
| `(db/delete-key! ref)` | 1 | Whether the key existed; one write transaction. |
| `(db/present? ref)` | 1 | Whether the key exists. |
| `(deref ref)`, `@ref`, `(db/deref ref)` | 1 | The stored value or nil; one read transaction. `db/deref` is the universal `deref` (vars, atoms, reduced too); another kind is `:not-derefable`. |
| `(db/begin-write conn)` | 1 | A write transaction; a second one on the same connection while one is open is `:db/busy`. |
| `(db/begin-read conn)` | 1 | A read transaction. |
| `(db/commit! tx)` | 1 | nil; the transaction is over even when the commit fails. Any use of a finished transaction is `:tx-closed`. |
| `(db/abort-write! tx)` / `(db/abort-read! tx)` | 1 | nil; aborting a finished transaction is nil. |
| `(db/put! tx ref v)` | 3 | nil. A read transaction here is `:kind-mismatch`. |
| `(db/get tx ref)` / `(db/get tx ref default)` | 2–3 | The value through either transaction kind, the transaction's own writes included, or `default`. |
| `(db/delete! tx ref)` | 2 | Whether the key existed. |
| `(db/alter! tx ref f & args)` | 3+ | Writes and returns `(apply f current args)`, `current` nil when absent; when `f` throws, nothing is written. |
| `(db/scan tx tree)` / `(… start)` / `(… start end)` | 2–4 | An eager vector of `[key value]` in key-byte order, keys as keywords; `start` inclusive, `end` exclusive, each a keyword or symbol. An absent tree is `[]`. |
| `(db/reduce-tree tx tree f init)` | 4 | `(f acc key value)` over the whole tree in key order; `init` for an absent tree. |
| `(db/snapshot conn)` / `(db/release-snapshot! snap)` | 1 | `db/begin-read` and `db/abort-read!` under the snapshot names. |
| `(db/snapshot? x)` | 1 | Whether `x` is a read transaction not yet released. |
| `(with-tx [tx conn] body…)` | macro | Begins a write, commits after body and returns its value; when body throws, aborts and rethrows. |
| `(with-read-tx [tx conn] body…)` | macro | Begins a read and aborts it after body, whether or not body throws. |
| `(with-snapshot [snap conn] body…)` | macro | `with-read-tx` under the snapshot names. |

A read transaction sees the store as of when it began and nothing
committed after. A held snapshot keeps emdb from reclaiming the pages
it sees, so release what you pin. A transaction handle lives until VM
teardown; one never finished keeps its connection from closing.

**Absent.** Cursors as Values (PLAN §15.8; `db/scan` and
`db/reduce-tree` are the eager surface), a lazy `db/scan`,
`db/cursor`, `with-read-tx-at`, `db/as-of`, `db/pin-snapshot`,
`with-db`, `(deref r :using db)` and `db/snapshot-stats` (PLAN §15.7).
Point-in-time database values are Nextomic's (`docs/NEXTOMIC.md` §4).
