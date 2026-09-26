## DB.md — Durable identities & emdb integration

Authoritative contract for `src/db.zig` and the `db/*` language surface
built on it (the db natives in `src/stdlib.zig`, the `with-tx` family
in `src/stdlib/core.nx`). Derivative from `PLAN.md` §23 #5, #6, #7
and #22 (one isolate, explicit transactions, durable identities, as-of
reads); values cross the store as `docs/CODEC.md` bytes;
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
the nexis surface is single-isolate (PLAN §23 #5).

---

### 2. `store_id` derivation

emdb's meta page carries no file id, so `store_id: u128` comes from
the file's path. `open` resolves the canonical path before emdb opens
the file: the `realpath` of an existing file, and for a new file the
`realpath` of its directory joined with its name (a directory that
does not resolve is `:db/open-failed`). emdb opens the file at that
path, so every spelling of it takes the same lock file. The id is
computed over the canonical path of the file's `StoreFile` (§3.1), so
every connection sharing the file shares it. The low
64 bits are `hash.hashBytes(path)`; the high 64 bits are xxHash3,
seeded with `hash.seed`, over `"store-id"` followed by the path.

So `x.edb`, `./x.edb`, the absolute spelling and a symlink to it name
one store (the
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

A plain Zig struct, not a Value: it holds its file's `StoreFile`
(§3.1), the non-owning allocator, heap and interner the codec needs,
the two `store_id` halves, an open flag, a count of
open transactions and the tree-handle cache. The stdlib allocates each
one on the VM's allocator, records it in `vm.db_connections`, and
frees it only at VM teardown, so no address a Value holds is reused
while the VM lives. A `db_connection` Value (kind 31) is a pointer to
it; `db_write_txn` (32) and `db_read_txn` (33) point at a transaction
handle (§3.2).

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

**Walks.** `db/scan` and `db/reduce-tree` walk a tree with a `Walk`,
an emdb cursor that decodes each entry before advancing: a multi-page
value is assembled in the transaction's buffer, valid until the next
multi-page read on that transaction. emdb leaves undefined what a
cursor sees once its own tree is written under it, so a walk over a
write transaction registers on it, and a `put` or `del` to the walked
tree first copies the entries the walk has yet to visit, keys and
values, onto the connection's allocator. The walk then goes on over
the copy: it sees the tree as it was when it began, as a Clojure
`reduce` never sees its own updates. A walk nothing writes under copies
nothing; one whose callback writes its tree pays one copy of the rest
of the tree, at the first such write.

**Closing.** `close` aborts every transaction the language holds on
the connection (§3.2), releases the `StoreFile` and leaves the struct
in place with the open flag false: a ref or connection Value that
still names it reports the connection closed, and a handle reports its
transaction closed. A second `close` does nothing. `close` while a
native holds one of the connection's transactions for a callback, or
while a Zig-level transaction is open, is refused (`TransactionsOpen`),
so no emdb transaction outlives its environment and no callback loses
the transaction its native is using. `shutdown` ends and frees the
connection's handles and closes whatever is open, for VM teardown.

**A failed commit aborts.** emdb leaves a transaction whose commit
failed open, holding the write lock; `commit` aborts it before
returning the error, so the transaction is over either way.

#### 3.1 One environment per file

emdb's writer lock is per file and process and waits for its holder,
so two environments on one file in one process would deadlock (the
second writer waits on the first, which the same thread holds), and
one opened through another spelling of the path would take a lock
file of its own and write beside the first. A process therefore opens
each store file once: `StoreFile.acquire` keeps the open files in one
process-wide list keyed by `(st_dev, st_ino)`, and every `open` of the
file, through any spelling or symlink, and every Nextomic `connect` to
it (`docs/NEXTOMIC.md` §2) share its one `emdb.Env`,
reference-counted; the last `release` closes it. A copy of a store
file is another file.

**Hard links are refused.** Across processes the lock is emdb's:
its writer lock and reader table live in `<path>-lock`, named after
the path the environment opens. The canonical path (§2) makes every
spelling and symlink of a file one lock file, but no path names a file
for all its hard links, and emdb takes no lock path of its own. Two
processes opening a store by two hard-link names would take two lock
files: two writers at once, and each writer blind to the other's
readers, reusing pages they still read. So `acquire` refuses a
regular file whose link count is above one, at every `open` and
`connect`, whether or not the process has it open already:
`HardLinked`, `:db/hard-linked` (a directory's links are its entries,
and emdb refuses it as a store). Removing the extra name makes the
file openable again; a copy of it is another store.

The environment has one write transaction. `StoreFile.beginWrite`
while any holder of the file has one open is `WriterActive`
(`:db/busy`; Nextomic reports it as `:nextomic/nested`), never a wait.
Read transactions run beside it. The first open sets the environment's
options and allocator, which outlive every connection to the file:
`db/open` and Nextomic's `connect` both pass the VM's allocator, which
outlives every connection the VM makes. A file the process may read
but not write opens read-only, and every write on it is
`:db/read-only`.

#### 3.2 Transaction handles

A transaction the language begins (`db/begin-write`, `db/begin-read`,
the `with-tx` family) is a `Handle`: the emdb transaction, whether it
is still open, how many natives hold it for a callback (§12) and a
reached flag, allocated on the connection's allocator and kept in one
process-wide list. It ends by commit or abort, by `close` of its
connection, or by a collection:

- The collector flags every handle a Value of it reaches while it
  marks, and after marking ends every handle of its heap that is
  neither flagged nor held, aborting a write and ending a read, and
  frees it (`GC.md` §5). A transaction the program drops without
  committing or aborting it is therefore aborted by the first
  collection that finds nothing holding it. A slot of a running
  frame that still holds a copy of it counts (`GC.md` §3): a
  handle a function dropped can stay open in its caller's window
  until the slot is reused or the caller returns.
- A handle whose transaction has ended stays allocated while a Value
  names it and reports `:tx-closed`; the first collection that finds
  it unreachable frees it, and teardown frees the rest.
- Beginning a transaction when the file's writer is taken
  (`WriterActive`) or emdb's 126 reader slots are full
  (`ReaderTableFull`), while a handle this VM could collect holds a
  transaction on the file, runs one collection and begins again. So
  dropped transactions never hold the writer against a later write,
  or the reader slots against a later read, of the same VM; a live
  writer is still `:db/busy` and 126 live reads still make the next
  `:db/readers-full`.

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
`InvalidTreeName`, `InvalidKey`, `TransactionsOpen`, `HardLinked`;
emdb, codec, intern and allocator errors propagate unchanged.

| Function | Contract |
|---|---|
| `open(allocator, heap, interner, path, options) !Connection` | §2, §3. |
| `StoreFile.acquire(path, options) !*StoreFile` / `release(*StoreFile)` / `beginWrite(*StoreFile, options) !*emdb.Txn` | §3.1. |
| `close(*Connection) DbError!void` / `shutdown(*Connection) void` | §3. |
| `storeId(*const Connection) u128` | §2. |
| `beginWrite(*Connection) !WriteTxn` / `beginRead(*Connection) !ReadTxn` | `ConnectionUnavailable` on a closed connection. |
| `commit(*WriteTxn) !void` / `abortWrite(*WriteTxn)` / `abortRead(*ReadTxn)` | End the transaction; a failed commit aborts (§3). |
| `Handle.create(txn) !*Handle` / `Handle.end(*Handle)` / `handleOf(Value) *Handle` | §3.2; `end` aborts a transaction still open. |
| `markHandle(Value)` / `sweepHandles(*Heap, complete)` | The collector's two calls (§3.2, `GC.md` §5). |
| `collectableHandles(*const Connection) bool` / `handleCount() usize` | Whether a collection could end a transaction on the connection's file; the handles alive in the process. |
| `Walk.begin(*Walk, txn, tree) !bool` / `first(?start)` / `next()` / `end()` | A walk (§3); `begin` is false for an absent tree. |
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
| `close` while a native holds one of its transactions (§12) | `TransactionsOpen` | `:db/busy` |
| A store file with more than one hard link (§3.1) | `HardLinked` | `:db/hard-linked` |
| A write while any connection or Nextomic store of the file holds its writer | `WriterActive` | `:db/busy` (§3.1) |
| A write on a file opened read-only | `TxnReadOnly` | `:db/read-only` |
| A second `close` | none | none (nil) |
| Encode of a kind with no serialized form (CODEC.md §3) | `UnserializableKind` | `:unserializable` |
| Stored bytes that do not decode | any other `CodecError` | `:codec-failed` |

emdb errors map by `failureName`: `:db/key-too-large` (a key past
4078 bytes, emdb's bound for the pinned 16 KiB page),
`:db/value-too-large` (an encoded value past 65 535 overflow pages,
just under 1 GiB), `:db/max-trees` (a file holds at most 128 named
trees, Nextomic's twelve among them when it shares the file),
`:db/not-found`,
`:db/corrupted` (also a file that is not a store, and a format-version
mismatch), `:db/map-full`, `:db/mmap-failed`, `:db/open-failed`,
`:db/page-size-mismatch`, `:db/busy` (a writer already active, the
environment busy), `:db/readers-full` (126 read transactions open on
the file, emdb's reader table; §3.2), `:db/txn-aborted`,
`:db/read-only`, `:db/sync-failed`; anything else is `:db-error`.
Nextomic shares these `:db/*` names through the same function.

The natives throw them with `vm.throwKeyword`, so `(catch any e …)`
binds the keyword and, outside any `try`, the throw is uncaught like
every recoverable error. Equality and hash are unaffected by any
failure: the triple is fixed at construction.

**Two connections to one file.** A ref made on one connection is
accepted in a transaction of another connection to the same store.
Both share the file's environment (§3.1), so a write through the
second while the first holds the writer is `:db/busy`.

---

### 9. Codec integration

Values are CODEC.md bytes. A durable ref inside a stored value is
`:unserializable`: the kind is not in the serializable set
(CODEC.md §3).

---

### 10. Tests

`test/prop/db.zig` is the emdb round-trip property test: D1 writes 10 000 random
values across 5 named trees and reads each back equal with an equal
hash; D2 closes, reopens the file with a fresh heap and interner, and
reads 2 000 values back; D3 checks that the identity triple alone
decides ref equality and hash; D4 writes the same key to every tree
with different values and reads each tree's own back. The inline tests
in `src/db.zig` pin the canonical store id, the pinned geometry, the
refusal of a hard-linked file, close refused while a transaction is
open, the tree-handle cache, `ConnectionUnavailable`, `StoreMismatch`
and the invalid names. The language surface runs in
`test/integration/eval_pipeline.zig` (among them: close aborting open
transactions, ten thousand dropped reads and dropped writes under the
default and the stress collection policies, and a `db/reduce-tree`
whose callback writes, deletes and walks the tree under it),
`test/integration/runtime_polish.zig` and `examples/durable-refs.nx`.

---

### 11. Module graph

`db.zig` imports `value`, `heap`, `intern`, `hash`, `codec` and
`emdb`. `dispatch.zig` and `gc.zig` call its hash, equality and trace
helpers at their `.durable_ref` arms, and `gc.zig` its `markHandle`
and `sweepHandles` (§3.2); `format.zig` reads a ref's
tree name and key bytes to print it; `stdlib.zig` holds the natives;
Nextomic imports it only for `failureName`, the geometry constants
`page_size` and `max_named_trees`, and `StoreFile`, through which it
shares the file's environment (§3.1); it keeps raw byte keys and never
goes through `db.zig`'s connections, trees, codec calls or refs.

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
| `(db/open path)` | 1 | A connection; creates the file and its parent directories. A file the process may only read opens read-only. |
| `(db/close conn)` | 1 | nil; aborts the connection's open transactions, whose handles then report `:tx-closed` (§3); closing twice is nil; from a callback a native runs over one of its transactions, `:db/busy`. |
| `(db/ref conn tree key)` | 3 | A durable ref (§4); prints `#<durable-ref :tree hex:…>`. |
| `(db/ref? x)` | 1 | Whether `x` is a durable ref. |
| `(db/put-key! ref v)` | 2 | nil; one write transaction around one put. |
| `(db/get-key ref)` / `(db/get-key ref default)` | 1–2 | The stored value, or `default` (nil); one read transaction. |
| `(db/delete-key! ref)` | 1 | Whether the key existed; one write transaction. |
| `(db/present? ref)` | 1 | Whether the key exists. |
| `(deref ref)`, `@ref`, `(db/deref ref)` | 1 | The stored value or nil; one read transaction. `db/deref` is the universal `deref` (vars, atoms, reduced too); another kind is `:not-derefable`. |
| `(db/begin-write conn)` | 1 | A write transaction; while any connection or Nextomic store of the same file holds one, `:db/busy`. |
| `(db/begin-read conn)` | 1 | A read transaction; with 126 open on the file, `:db/readers-full`. |
| `(db/commit! tx)` | 1 | nil; the transaction is over even when the commit fails. Any use of a finished transaction is `:tx-closed`. |
| `(db/abort-write! tx)` / `(db/abort-read! tx)` | 1 | nil; aborting a finished transaction is nil. |
| `(db/put! tx ref v)` | 3 | nil. A read transaction here is `:kind-mismatch`. |
| `(db/get tx ref)` / `(db/get tx ref default)` | 2–3 | The value through either transaction kind, the transaction's own writes included, or `default`. |
| `(db/delete! tx ref)` | 2 | Whether the key existed. |
| `(db/alter! tx ref f & args)` | 3+ | Writes and returns `(apply f current args)`, `current` nil when absent; when `f` throws, nothing is written. |
| `(db/scan tx tree)` / `(… start)` / `(… start end)` | 2–4 | An eager vector of `[key value]` in key-byte order, keys as keywords; `start` inclusive, `end` exclusive, each a keyword or symbol. An absent tree is `[]`. |
| `(db/reduce-tree tx tree f init)` | 4 | `(f acc key value)` over the whole tree in key order, as it was when the walk began whatever `f` writes to it (§3); `init` for an absent tree. |
| `(db/snapshot conn)` / `(db/release-snapshot! snap)` | 1 | `db/begin-read` and `db/abort-read!` under the snapshot names. |
| `(db/snapshot? x)` | 1 | Whether `x` is a read transaction not yet released. |
| `(with-tx [tx conn] body…)` | macro | Begins a write, commits after body and returns its value; when body throws, aborts and rethrows. |
| `(with-read-tx [tx conn] body…)` | macro | Begins a read and aborts it after body, whether or not body throws. |
| `(with-snapshot [snap conn] body…)` | macro | `with-read-tx` under the snapshot names. |

**A callback holds its transaction.** `db/alter!` holds its
transaction handle while it calls `f`, and `db/reduce-tree` while it
walks: `db/commit!`, `db/abort-write!`, `db/abort-read!`,
`db/release-snapshot!` of a held handle and `db/close` of its
connection are `:db/busy`, so no callback finishes a transaction a
native is still using. A throw from the callback ends the hold before
it propagates, so `with-tx` aborts as usual; reads and writes through
the handle, a nested `db/alter!` or `db/reduce-tree` included, are
allowed. `db/scan` is eager and calls nothing back.

A read transaction sees the store as of when it began and nothing
committed after. A held snapshot keeps emdb from reclaiming the pages
it sees, so release what you pin. A transaction the program drops
unfinished is aborted by a collection that finds nothing holding it,
and by `db/close` of its connection (§3.2).

**Absent.** Cursors as Values (`db/scan` and
`db/reduce-tree` are the eager surface), a lazy `db/scan`,
`db/cursor`, `with-read-tx-at`, `db/as-of`, `db/pin-snapshot`,
`with-db`, `(deref r :using db)` and `db/snapshot-stats`.
Point-in-time database values are Nextomic's (`docs/NEXTOMIC.md` §4).
