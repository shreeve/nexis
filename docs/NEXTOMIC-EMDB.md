# NEXTOMIC-EMDB.md: What Nextomic relies on in emdb

**TL;DR: Nextomic, the Datomic-class database of this repository, is
built on emdb (`../emdb`). It requires zero changes to emdb: every capability it needs is a committed invariant or a public
function of the engine as it stands, and keeping it that way is the
point. This file names those capabilities, records the engine facts that
constrain the Nextomic key design, and lists the temptations to refuse
when they come up.**

---

## 1. What Datomic is, and what Nextomic is

### 1.1 Datomic

Datomic is a database created by Rich Hickey, the author of Clojure. It
stores facts, not rows. A fact is a tiny statement: entity 42 has
attribute "name" with value "Alice", recorded in transaction 900.
Datomic calls this a datom.

Most databases overwrite. When Alice changes her name, the old name is
gone. Datomic never overwrites. It adds a new fact and marks the old one
as retracted. The database is a growing pile of facts, each stamped with
the transaction that added it.

**Why it exists.** Hickey's argument was that a database should behave
like a value, the way a number or a string does. You can hold a value,
pass it around and compare it, and it never changes under you. A
traditional database is a place that mutates. That makes questions like
"what did we know last Tuesday?" or "who changed this and when?" awkward
or impossible. Datomic makes them trivial.

**How it works.** Every fact is stored several times in different sort
orders, so any question has a fast path:

- sorted by entity, for "tell me everything about Alice"
- sorted by attribute, for "list every name in the system"
- sorted by attribute then value, for "who is named Alice?"
- sorted by referenced entity, for "who points at Alice?"

Because facts carry their transaction stamp, three time-travel
operations fall out for free. You can read the database as of any past
point. You can ask what changed since a point. You can see the full
history of any fact.

Queries use Datalog, a small logic language: you describe the pattern of
facts you want and the engine finds them. Writes go through one process,
the transactor, so there is exactly one order of events, and readers
never block writers.

**What makes it unique.** Immutable facts, time built into every fact,
and a single ordered writer. Auditability, reproducible reads and time
travel are not features bolted on; they are the storage model. Almost
nothing else does this, and the open-source imitators run on the JVM
with a heavy runtime and slow startup.

### 1.2 Nextomic

Nextomic is the same idea, built in Zig on top of emdb and nexis, a Lisp
with Clojure-style values. The design needs zero changes to emdb.

**How it maps.** A datom becomes a byte string in emdb: entity,
attribute, value, transaction, packed so that plain byte order is the
right sort order. Each Datomic index is one named tree in a single emdb
file. A transaction writes to all the index trees plus a log tree, and
emdb publishes them together in one atomic step. A query opens one emdb
read transaction and reads Nextomic's own transaction number inside it;
that number is the basis point in time. Time travel is a range filter on
the transaction part of each key, so no special engine support is
needed.

**Where it can be better than Datomic.**

- **Startup.** Datomic needs a JVM and usually a separate transactor
  process. Nextomic opens an mmap file and answers in milliseconds. That
  fits local-first apps, command-line tools and on-device agents that
  need memory.
- **Raw speed.** emdb leads LMDB 1.0.2 on every row of the PERFORMANCE
  §12.2 campaign. Scans and history walks run straight through the
  mapping with SIMD compares and no object deserialization.
- **Interactive development.** A query expands to a visible plan at the
  REPL in under a millisecond.
- **Zero engine coupling.** Every piece Nextomic needs is an existing
  emdb invariant or public function, which is why the rest of this note
  lists things to refuse rather than things to add.

**Where it will not win, on purpose.** Datomic is a distributed system
with a decade of query planner work. Nextomic targets one machine, one
writer, mostly reads, with a simple correct planner first. That is a lane
with real demand and no dominant player.

---

## 2. Context

Nextomic needs nothing emdb-shaped: it composes named trees, cursors,
range scans, prefix deletes and read transactions on the nexis side.
`docs/NEXTOMIC.md` is the design; this file captures the emdb-side
implications only.

---

## 3. The basis-tx, and where to take it from

Nextomic's database-as-value ("db-value") carries a **basis-tx**, the
transaction number at which the value was captured, used to drive
`as-of`, `since` and `history` through tx-in-key range scans.

The basis is Nextomic's own logical transaction number `t`, minted by
Nextomic and stored in its `sys` tree in the same emdb write transaction
as the datoms it stamps. A db-value reads `t` inside a pooled read
transaction and closes it; every later operation on that db-value opens
its own read transaction and reads `t` again inside the same snapshot it
queries, so the basis and the data never disagree. The db-value pins no
reader slot.

The engine's `Txn.txnId` is not used in any key or entity id, on
purpose: it advances for every commit to the file (including writes to
other trees), is reused after `Env.rollback()`, and would need masking
to serve as a transaction entity id. `Env.info().lastTxnId` (API-E06)
has the further problem of lagging a commit from another process. A
number Nextomic commits alongside the datoms can never be ahead of, or
behind, the data it describes.

---

## 4. What Nextomic needs from emdb: all present

| Nextomic need | In emdb, by name |
|---|---|
| Twelve named trees (four current indexes EAVT, AEVT, AVET, VAET; four history indexes with the transaction in the key; txlog, idents, sys; a full-text tokens tree created on demand) | Named sub-databases: INV-SUB01..06; `Txn.openTree(name, create)`, `getFromTree`, `putInTree`, `delFromTree`, `openCursorForTree`, `openWriteCursorForTree`, `treeStat`, `dropTree`. `EnvOptions.maxNamedTrees` defaults to 128; a `TreeId` survives across transactions (INV-SUB03) |
| Binary-sortable composite keys | Unsigned lexicographic byte order, API-K03, `emdb.defaultKeyCmp` over `simd.compare` |
| Snapshot isolation for one query across all indexes | INV-T02, INV-T03: one read transaction is one consistent snapshot over every tree |
| Atomic multi-index commit | INV-SUB04 (named-tree roots and the main-tree `TreeStat` entries commit together), INV-T07A, INV-M02, INV-M03: one meta-page publish; every image a power loss can leave is enumerated by `test/crash.zig` (SPEC §10.3) |
| A cheap db-value per query | Retained transaction pool: `Env.txnPool` keeps finished transactions with their arenas, 8 to 64 by `maxReaders` (PERFORMANCE §6.18, R-TXN 11.3M begin/get/abort per second in §12.2). A read transaction is a pooled object, safe to begin and finish from any thread |
| `as-of` / `since` / `history` by tx-in-key filtering | `Cursor.set`, `setRange`, `first`, `last`, `next`, `prev` (API-C01, API-C02). A seek from a positioned cursor resolves on its leaf or the right sibling without a descent (§6.22), so skip-scans between `[e][a]` groups are cheap |
| Point lookups in key order (pull, sorted lookup-ref probes) | Per-tree search clue with position hint, INV-CL01..CL05 in `../emdb/src/txn.zig` (§6.13): an ascending run of `get` calls costs one comparison each |
| Full index scans | Inlined cursor step with lookahead prefetch (§6.14): SCAN-FWD 311M and M-ORDER 247M entries per second in §12.2 |
| Entity excision, attribute retirement, index rebuild | `Txn.delPrefix` / `delPrefixFromTree` drop covered leaves as pages (§6.23, M-KILL 171M deletes per second); `dropTree(dbi, false)` empties an index for a rebuild. The key shapes make every entity, attribute and ref-target range a prefix |
| Bulk import in large transactions | No mid-transaction write-back (INV-WM05, §6.21): a 1M-put transaction runs at the 10K-put rate. Append-biased splits (§6.16) and populate-ahead (§6.15) for ascending EAVT and txlog keys; the seal runs on `EnvOptions.sealThreads` threads for the random-order AVET and VAET writes (§6.26) |
| Durability choices per transaction | `Env.beginWriteWith(.{ .sync = .none / .noMeta / .full })` (API-TX06, INV-SYNC-03) and `Env.sync()` (API-E10) to end a `.none` load; `Txn.prepare()` for two-phase commit (INV-T07B) |
| Integrity without a Nextomic checksum layer | Every page carries a transaction stamp and a CRC-32C over its live bytes (INV-S12, INV-S13, format version 3), verified on first touch, `EnvOptions.verifyChecksums`, `Env.lastCorruption()` |
| Parallel query workers | Lock-free reader registration and wait-free reads (INV-T13, INV-T14B): R-PAR scales eight readers at 1.32x LMDB in §12.2. Read-only children of a write transaction (INV-T15A, `Txn.beginReadChild`) read uncommitted state from other threads |
| Physical replication and one-step undo | `Env.backup(sinceTxnId, out)` incremental by transaction id, `Env.restore`, `Env.rollback()`, `EnvOptions.previousSnapshot` (INV-BK01..04, INV-RB01..03) |

Nextomic encodes a current-index key as `[E(e)][A(a)][v:type-tagged-sortable]`
(in each index's order; `E(e)` the entity id as a class-and-length
header and its minimal offset, `A(a)` the attribute id as an ordered
varint, NEXTOMIC.md §2) with the `t` of the fact's latest assertion, a
LEB128, as the value, and a history key as the same bytes followed by
`[(t << 1) | added : 6]` with an empty value. A history tree holds only
retired rows, a retraction and the assertion it retired, so a store
that only adds facts leaves it empty, and a time view walks a current
tree and its history twin merged (NEXTOMIC.md §2, §4). emdb sees only
bytes; the encoding is Nextomic's concern, and the
default byte order is exactly the order Nextomic needs.

---

## 5. Engine facts that shape the Nextomic key design

**Leaf keys are stored whole.** Prefix compression applies to branch
separators only (INV-P03); separators are truncated to the shortest
distinguishing prefix (DEF-PREFIX, INV-P01) and a branch page factors
out one page-wide prefix when its keys share one (SPEC §5.0.2, §6.17). The benefit to composite datom keys is
fan-out and depth, not leaf density. Leaf density comes from the empty
values: a datom costs its key bytes plus the 8-byte node header and the
2-byte pointer, and nothing else.

Leaf prefix compression was measured on datom keys and declined
(PERFORMANCE §6.27): within a 16K leaf only the high bytes of the leading
component repeat, so a page-wide prefix saves 14 to 23% of the file and
front coding 27 to 29%, while a prototype put scans at half to two thirds
of their rate. Two Nextomic-side levers return more at no engine cost,
and both are in the design: short keys (an entity of two to four bytes
and an attribute of one or two, each order-preserving and giving its
own length, a 6-byte `t` with the op folded into it on history rows
alone), and sorting a
transaction's AVET and VAET inserts before they are written (leaf fill
0.66 to 0.72 → 0.90). Reopen only for a leaf set larger than RAM, under
the experiment §6.27 names.

**Keys have a hard bound and a soft one.** The hard bound is
DEF-MAXKEYSIZE, INV-S10: 4078 bytes at 16K pages, 1006 at 4K; every write
path refuses a longer key with `KeyTooLarge`, and `Env.maxKeySize()`
reports it. The soft bound is the search clue's 256-byte key buffer
(`clueMaxKey` in `../emdb/src/txn.zig`): a longer key still works but misses the
clue on every lookup. A string `v` in an index key should therefore be
capped (a prefix plus a hash, the full string beside `t` in the fact's
current `nx/eavt` row or on its retired `nx/eavt-h` assertion row,
NEXTOMIC.md §2.2), which
keeps the datom key under the soft bound and far under the hard one.

**Page size is a per-file decision and it is 16K.** `EnvOptions.pageSize`
defaults to the OS page (16K on Apple Silicon, 4K on Linux) and is
immutable for the file's life (INV-M05). It fixes the key bound above, the
overflow threshold, and tree depth (16K keeps 1M entries three levels
deep). Nextomic should pass `pageSize = 16384` explicitly and deploy the
file on its own ZFS dataset with `recordsize=16k` (PERFORMANCE §11.5).

**Zero-copy has a size limit.** `get` returns a pointer into the mapping
for inline values and single-page overflow values; a value spanning
several overflow pages is copied into a buffer of its own that the
transaction owns (API-KV01). The pointer is valid until the
transaction's next mutation or its end (API-KV01, INV-FL05). Index trees
hold `[t]` or nothing, except the out-of-line payloads in EAVT values
and on retired EAVT-h assertion rows; those and the txlog entries are
the multi-page values.

**Read transactions pin reclamation, not memory.** A read transaction
holds a reader slot; pages freed after its snapshot are not reused while
it lives (INV-T11, INV-FL02). The pool makes begin and end cheap; it does
not change this. A db-value holds none (§3): an operation reads in the
file's held snapshot, which the next commit lets go (`docs/DB.md` §3.4),
or in a fresh reader, so only a long-running operation pins pages. A
dead reader is swept by the writer on its own (INV-T14D).

**One writer, always.** INV-T04. `transact!` serializes on the write lock,
which is the transactor. A durable commit is two device flushes (D-FULL in
§12.2: 128 commits per second on the campaign machine). Nextomic never
batches transactions (NEXTOMIC.md §3); the lever is the sync a
connection or one `transact!` chooses (`:durability`, `:sync`).

**Register trees before workers start.** `openTree` on a name not yet in
`Env.treeNames` mutates environment state (the thread-safety note on
`treeNames` in `../emdb/src/txn.zig`). Nextomic opens all twelve trees once
at connect, in a read transaction (a write transaction only creates a
tree the file lacks); every later `openTree` from a reader only loads
per-transaction state and is safe from any thread.

---

## 6. What emdb must not become: temptations to refuse

Each has a correct nexis-side answer that keeps emdb uncoupled from
Nextomic's semantic model. The default answer to each is **no**.

### 6.1 Do not add a typed or configurable key comparator

Default unsigned-lex comparison is what binary-sortable tuple encoding
wants. The comparator is inlined at every probe (§6.19) and the search
clue's range test and position hint assume it. Nextomic encodes value
types into the key bytes so lex order is value order.

### 6.2 Do not add "read at arbitrary historical txn_id"

Pages freed by old transactions are reclaimed once no live reader pins
them (INV-T11, INV-FL02); that is the storage model. `previousSnapshot`
and `rollback()` reach exactly one commit back (INV-RB03) for operational
recovery and are not a history facility. Nextomic routes history through
tx-in-key filtering, which needs no page retention.

### 6.3 Do not add record, tuple or datom awareness to storage

emdb is a sorted KV store. Datoms are byte keys and codec-encoded values.
No `putDatom`, no typed columns, no schema-aware storage, no DUPSORT.

### 6.4 Do not add Nextomic-specific APIs

If Nextomic needs a new read pattern, it composes named trees, cursors,
range scans, prefix deletes and read transactions on the nexis side. A
"delete range" beyond a prefix is a cursor loop; every range Nextomic
needs to drop is a prefix by construction of its key shapes.

### 6.5 Do not turn `CommitObserver` into a transaction-log hook

`CommitObserver` is a durability test seam called on the committing
thread between commit steps, and production environments set none
(`../emdb/src/txn.zig`). Nextomic's txlog is a named tree written in the same
transaction as the indexes and committed atomically with them
(INV-SUB04); a change feed is a scan of the txlog from `basis + 1`.

### 6.6 Do not ask for concurrent writers

INV-T04 is the transactor. Nextomic keeps no queue and never joins two
`transact!` calls into one write transaction (NEXTOMIC.md §3).

### 6.7 Do not widen the clue buffer or the key bound for long values

Both follow from the page size and the leaf layout. Long strings belong
in a value (the `nx/eavt-h` payload); index keys carry a capped prefix
and a hash.

---

## 7. Cross-references

- `../emdb/SPEC.md`: the 7-layer formal specification and invariant catalog
- `../emdb/AGENTS.md` §"What NOT To Do": related architectural discipline
- `../emdb/PERFORMANCE.md` §6.13 through §6.26: the shipped optimizations
  named above; §11.5: page size and ZFS record size; §12.2: the benchmark
  campaign against LMDB 1.0.2
- `../emdb/src/emdb.zig`: `EnvOptions`, `Env`, `Env.Info`
- `../emdb/src/txn.zig`: `Txn`, `SearchClue`, `SyncOverride`, `CommitObserver`
- `../emdb/src/cursor.zig`: `Cursor`, `WriteCursor`
- `docs/NEXTOMIC.md`: full Nextomic architecture

---

*If a change to emdb is proposed on Nextomic's behalf, this file is the
reason to push back first.*
