# NEXTOMIC.md — A Datomic-class database on nexis + emdb

This is the authoritative design for Nextomic: the storage layout, the
transaction protocol, the db-value semantics, the query pipeline and the
Lisp API. Code follows this document; when they disagree, fix one in the
same commit. The emdb-side view (what the engine already provides and
what must not be asked of it) is `../emdb/NEXTOMIC.md`; its §1 is the
reader's introduction to Datomic and Nextomic.

Nextomic requires **zero changes to emdb**. Every engine capability used
below is a public function or a committed invariant of emdb as it stands
(§11).

---

## 1. Commitments

1. **Datoms in emdb named trees, bytes only.** A datom is
   `[e a v tx added]`. emdb sees byte keys whose unsigned lexicographic
   order is the index order. No engine-side type awareness.
2. **Current and history are separate trees.** Four current indexes hold
   only asserted facts and answer ordinary reads with no per-fact fold.
   Four history indexes hold every assertion and retraction with the
   transaction in the key and answer `as-of`, `since` and `history`.
3. **Logical transaction numbers.** Nextomic mints its own monotonic `t`
   (stored in the `sys` tree, committed atomically with the datoms). The
   engine's `txnId` never appears in a key or an entity id.
4. **A db-value is a plain value** `{store, basis, mode}` with no open
   read transaction. Each operation opens a pooled read transaction for
   its own duration and closes it.
5. **Integer entity ids in partitions**, never durable-refs.
6. **Schema is datoms** on attribute entities, read as-of the basis.
7. **`q` is a native function** taking a query value; queries are data,
   composable and storable. Macros are sugar only.
8. **All Nextomic memory is arena-scoped per operation**; only results
   are copied into the VM heap, and the arena dies on every path out of
   the operation, a throw included.

---

## 2. Store layout

`Store.open` opens its own emdb `Env` with the geometry every nexis
store shares (`db.page_size` = 16 KiB, `db.max_named_trees` = 128). A
new file starts at the map size its opener names
(`Store.Options.map_size`: 1 MiB, `Store.initial_map_size`, unless
named; a connection names `nextomic.db.OpenOptions.map_size`, 256 MB)
and emdb extends a full file 8 MiB at a time (`Store.map_grow_step`).
emdb reserves the address space when it opens a file, so an extension
moves no mapping and costs one `ftruncate`; the file's length is the
map, and its allocated blocks are the pages written. emdb reads a
file's page size from its meta and fixes it for the file's life
(INV-M05), so
a store is never opened another way and the 4078-byte hard key bound
holds on every platform. Keys never approach it except a keyword's
text (§2.1 below). A stored value, whether a datom's full string or
byte array in EAVT-h or a transaction's txlog entry, is at most 65 535
overflow pages, just under 1 GiB; past that the engine refuses the
write as `:db/value-too-large` and the transaction aborts.

Connect opens all twelve trees, reads the `sys` header and finds
`:db/fulltext` in one read transaction, and caches the `TreeId`s for
the connection's life (tree registration is the engine's one call that
is not thread-safe, and it happens only here). Only a store missing one
of them takes a write transaction at connect: a new file is
bootstrapped, a tree the file lacks is created, and `:db/fulltext` is
minted (§2.4). One more write can follow the open: when the
`nx/fulltext` rows are stale (§2.3 `"ft"`) and some attribute is
full-text, `Conn.open` rebuilds them in a write transaction of its own
that writes no datom, and skips the rebuild on a file it may only read
or whose writer this process holds. So opening a complete store with
current rows writes nothing, waits on no writer, and succeeds on a file
the process may only read, where every `transact!` is `:db/read-only`.

emdb's writer lock is per file and makes a second writer wait for the
first to end. Every connection to one file in the process, and every
`db/*` connection to it, shares the file's one environment
(`db.StoreFile`, `docs/DB.md` §3.1; files are told apart by device and
inode, so a symlink is the same file and a copy is another, and a file
with a second hard link is refused, `:db/hard-linked`). A write
through one while another holds the file's write transaction is
`:nextomic/nested` from Nextomic and `:db/busy` from `db/*`, never a
wait on itself.

| tree | key | value |
|---|---|---|
| `nx/eavt` | `[e:6][a:4][v]` | `[t:6]` (format 1 also wrote the payload of an out-of-line value after it) |
| `nx/aevt` | `[a:4][e:6][v]` | `[t:6]` |
| `nx/avet` | `[a:4][v][e:6]` | `[t:6]` (indexed and unique attrs only) |
| `nx/vaet` | `[v:6][a:4][e:6]` | `[t:6]` (ref attrs only) |
| `nx/eavt-h` | `[e:6][a:4][v][top:6]` | empty, or on an assertion row the full payload of an out-of-line value |
| `nx/aevt-h` | `[a:4][e:6][v][top:6]` | empty |
| `nx/avet-h` | `[a:4][v][e:6][top:6]` | empty (indexed and unique attrs only) |
| `nx/vaet-h` | `[v:6][a:4][e:6][top:6]` | empty (ref attrs only) |
| `nx/txlog` | `[t:6]` | codec vector `[instant [e a v added] ...]`, with a trailing map `{:excised [e ...]}` on an entry an excision touched |
| `nx/idents` | `[0x00][utf8 text]` / `[0x01][id:4]` / `[0x02][utf8 text]` | id / text / id of a name a rename retired |
| `nx/sys` | `"format"`, `"uuid"`, `"t"`, `"eid"`, `"aid"`, `"ig"`, `"sg"`, `"ft"`, `"n"[a:4]` | see §2.3 |
| `nx/fulltext` | `[a:4][token][0x00][e:6][hash128(v):16]` | empty; one row per token of each current string value of a `:db/fulltext` attribute (§5 "fulltext") |

`top` = `(t << 1) | added`. `v` is always followed only by fixed-width
fields, so it is `key[prefix .. len - suffix]` with no length byte.

### 2.1 Identifiers

All ids are stored big-endian in 6 bytes and fit the VM's `fixnum`
(i48), so the usable range is `0 .. 2^47-1`. An id, a `t` or a `sys`
counter read back from the file outside its range is `:db/corrupted`,
never trusted; a partition or `t` that would run past its range is
`:db/map-full`.

| partition | range | source |
|---|---|---|
| attributes and idents | `1 .. 2^32-1` | `sys/"aid"`; an attribute entity's eid **is** its 4-byte `a` |
| user entities | `2^32 .. 2^46-1` | `sys/"eid"` |
| transaction entities | `2^46 \| t` | the logical `t` of the transaction |

`t` starts at 1 and increases by one per committed `transact!`. Because
`t` lives in the same file as the datoms and commits with them, a crash
or an engine-level rollback can never leave `t` ahead of the data.

Keyword *values* (enums) are interned in `nx/idents` exactly like
attributes and stored as 4-byte ids, so `:db/ident` refs and enum values
are the same mechanism. They sort by id, not by text. An ident's text
is a property of its id, not a datom value; a rename (§3 step 5) moves
the old text to the retired names, which only the txlog decoder reads
(an entry spells keywords by the names they had when it was written).
Since the text is an `nx/idents` key after its prefix byte, a keyword
the store holds, as an ident or a value, is at most 4077 bytes
(`idents.max_name_len`); a transaction that would mint a longer one is
`:nextomic/tx-data` naming the bound, and a read of one finds nothing.

### 2.2 Sortable value encoding

One tag byte orders types; within a type, byte order equals value order.

| tag | type | bytes |
|---|---|---|
| `0x02` / `0x03` | boolean false / true | none |
| `0x10` | long | `i64 ^ 0x8000_0000_0000_0000`, big-endian |
| `0x18` | double | IEEE bits `b`: sign set → `~b`, else `b ^ 0x8000…`; `-0.0` stored as `+0.0`; NaN rejected (`:nextomic/value-type`) |
| `0x20` | instant | i64 milliseconds, encoded like long |
| `0x30` | keyword | `[ident-id:4]` |
| `0x40` | ref | `[eid:6]` |
| `0x50` | string ≤ 96 bytes | UTF-8 with `0x00 → 0x00 0xFF`, terminated by `0x00` |
| `0x50` | string > 96 bytes | first 64 escaped bytes, `0x00`, `0x01`, then a 128-bit hash of the whole string |
| `0x60` | uuid | 16 bytes |
| `0x70` | bytes | as string, both shapes |

A long or an instant is any integer in i64, as Datomic's long is: a
fixnum, or a bignum past the fixnum range (`docs/SEMANTICS.md` §2.2),
goes in, and a read returns the language's integer for the stored
value, a bignum past `±2^47`. An integer outside i64 is
`:nextomic/value-type`, in tx-data, a lookup ref, a `datoms` component
or an `index-range` bound. A key holds every long in the same 8
bytes, and the txlog spells one past the fixnum range as the codec's
bignum; neither changes the format number. A build that takes longs in the
fixnum range only reads such a file's fixnum-range values and refuses
a wider one, `:nextomic/value-type` from an index and `:db/corrupted`
from the txlog, never misreading it. String order is UTF-8 byte order,
which is code point order, not UTF-16 order; no Unicode normalization
is applied.
Type tags never compare equal across types, so `1` and `1.0` are
different keys, in line with `(= 1 1.0)` being false.

**Out-of-line values** (strings and byte arrays over 96 bytes): the
index key is an equality key, not an order key. Byte order equals value
order across the threshold whenever two values differ within their
first 64 bytes. When two values agree on those 64 bytes, an out-of-line
one sorts after the inline value that is those bytes alone and before
any longer inline one (its `0x00 0x01` precedes every content byte),
and two out-of-line values order by hash (two seeded xxh3-64 lanes).
The decoder tells the shapes apart by the bare `0x00`: an inline value
ends there, an out-of-line one continues with `0x01` and the hash.
Range predicates compare decoded values, never index keys, so they are
exact on long strings. The full value is the value of each of the
fact's assertion rows in `nx/eavt-h` and nowhere else in the index
trees: a current read seeks the fact's latest EAVT-h row, which is its
assertion while the fact is current; a history read gets its own row,
and a retraction row, which holds nothing, the row before it, the
assertion it retracts. An AVET or AEVT hit on a long value is
confirmed by an EAVT point read before it is returned. A store format
1 wrote also holds the payload after `t` in the current EAVT row and
on its retraction rows, which reads take as they find.
Two distinct values with the same 64-byte prefix and the same 128-bit
hash under one `(e a)` are treated as one value; the probability is
2^-128 and the rule is documented rather than defended against.

Worst-case index key: AVET with a 96-byte string, `4 + 1 + 193 + 6 + 6
= 210` bytes, inside emdb's 256-byte search-clue buffer. An
`nx/fulltext` key reaches `4 + 255 + 1 + 6 + 16 = 282` bytes; a key
past 256 bytes bypasses the clue (a slower seek, not an error).

### 2.3 `sys` tree

| key | value |
|---|---|
| `"format"` | u16 Nextomic format number: 1 at bootstrap; 2 once a transaction asserts or retracts an out-of-line value, whose current EAVT row holds `t` alone and whose retraction rows hold nothing (§2.2). A build opens every format up to its own (2) and refuses a newer one as `:db/corrupted`, so no build misreads a current long value; a format-1 store needs no migration and becomes 2 in place |
| `"uuid"` | 16 random bytes minted at bootstrap: the store id, stable across renames |
| `"t"` | u48 last committed logical transaction number |
| `"eid"` | u48 next user entity id |
| `"aid"` | u32 next attribute / ident id |
| `"ig"` | u64 ident generation, bumped by every rename; absent reads as 0. A connection's ident cache remembers the generation it loaded under and reloads at the start of an operation when the store's has moved, so a rename in another connection or process is seen at once |
| `"sg"` | u64 schema generation, bumped by every transaction that writes a datom on an attribute-partition entity; absent reads as 0. A connection's schema cache serves a newer basis while the generation is the one it was built under and the txlog entries committed since hold no attribute-partition datom, since only data was committed; the entries settle it when the writer was a build that does not bump the generation, and each is read once per connection |
| `"ft"` | `[fold:1][t:6]`: the case folding the `nx/fulltext` rows were written under (2, Unicode simple case folding, §5 "fulltext") and the `t` they are current at; absent in a store an older build wrote, whose rows fold ASCII only. Bootstrap and every transaction stamp their `t`; a transaction that finds the stamp stale (another folding, or a `t` an older build committed without stamping) first rebuilds every row from the current values, as `Conn.open` does, and until a rebuild a search re-tokenises the values instead of reading the rows |
| `"n"` `[a:4]` | u64 count of the current datoms of attribute `a`, kept by every transaction and excision; the planner's estimate (§5) |

### 2.4 Bootstrap

The first open writes, with fixed ids so files from different builds
agree: the attributes `:db/ident`, `:db/valueType`, `:db/cardinality`,
`:db/unique`, `:db/index`, `:db/isComponent`, `:db/doc`,
`:db/txInstant`, the idents `:db.type/{long double instant keyword
ref string uuid bytes boolean}`, `:db.cardinality/{one many}`,
`:db.unique/{identity value}`, and the attribute `:db/fulltext`
(boolean, cardinality one) at id 22. Bootstrap is transaction `t = 1`.
A store whose idents lack `:db/fulltext` receives it at open, in a
transaction of its own at the store's next ident id, so its id is the
one the store reports (`Store.fulltext_aid`), not 22.

### 2.5 Write order and page fill

emdb splits a full leaf in half, except when the new key sorts after
every key on the leaf, when it keeps nine tenths on the left. A tree
written in ascending order at its right end therefore fills its
leaves to about 90 %, and one written in ascending order between
existing keys leaves every leaf behind it half full. Most of a
transaction's datoms land between existing keys: a new entity's EAVT
rows sort before the transaction entities (partition `2^46`), its
AEVT rows at the end of each attribute's run, its VAET rows at the end
of each referenced entity's.

`Store.writeBatch` writes each of the eight trees in turn, a current
tree before its history twin. It sorts one index's keys; those past
the tree's last key are appended in order. The rest go in two
ascending passes: the first over about 55 % of them, picked by
Fibonacci hashing of their rank so the two passes interleave evenly,
the second over the others, which land between the first pass's keys
on the half-full leaves it left behind. Equal keys stay in one pass in
batch order, so a batch leaves the trees exactly as writing its datoms
one at a time does. The gain grows with the keys a transaction writes
into one gap: one that takes less than a leaf's worth leaves its leaf
half full as before (`docs/PERF.md` §3.11 has the measured fill). The
order changes no byte of the format.

---

## 3. Transactions

One `transact!` is one emdb write transaction. The VM is single-threaded,
so there is no queue; emdb's write lock is the transactor.

1. **Begin**: `wtxn = env.beginWriteWith(.{ .sync = opt })`;
   `t = sys["t"] + 1`.
2. **Normalise** tx-data to `[op e a v]` ops. tx-data is a vector or a
   list of forms, each a list form or a map form (a hash map or a
   sorted map, as Datomic takes any map); anything else, or a malformed
   form, is
   `:nextomic/tx-data` with a `:message`. Entities may be an eid, a
   tempid (string, or a negative fixnum), a lookup ref `[:unique/attr v]`
   (`[:db/ident :kw]` names the entity that ident names), a keyword
   ident, or `"datomic.tx"` for the transaction entity. An explicit
   eid, as an entity or as a ref value, must have been handed out by
   its partition's allocator (a user id below `sys/"eid"`, an ident id
   below `sys/"aid"`, a transaction entity no newer than this
   transaction); any other id is `:nextomic/no-entity`, since it would
   collide with an id minted later. An allocated entity whose datoms
   were all retracted stays addressable. Attributes resolve through the
   ident cache (unknown → `:nextomic/unknown-attribute`); each `v` is
   converted by the attribute's `:db/valueType` (`:nextomic/value-type`
   when it cannot be). A keyword value an assertion names is minted
   when new (step 3); one a retraction or a lookup ref names is only
   matched, so a keyword the store has never seen retracts nothing,
   resolves no lookup ref and mints no id. Map forms `{:db/id e :attr v
   ...}` expand, a map without `:db/id` being a fresh tempid. A nested
   map under a component attribute becomes an entity with a fresh
   tempid; under any other ref attribute it must name its entity with
   `:db/id` or a unique attribute, since nothing could reach it
   otherwise (`:nextomic/tx-data`). Map forms nest as deep as the
   native stack allows (`stack.check`); past it the transaction aborts
   with the VM's `:stack-overflow`. A reverse key `:ns/_attr` in a map
   form asserts `[x :ns/attr e]` for each `x` under it: `{:db/id e
   :user/_friends x}` makes `x`, an entity or a map form of one, point
   at `e`, and a vector of them is one referrer each; the attribute must
   be a ref. Vectors under card-many attributes expand to one datom
   each, except that under a ref attribute a two-element vector whose
   first element names an attribute is one lookup ref (`{:user/friends
   [:user/email "a@x"]}` is one friend; `[[:user/email "a@x"] "tmp"]` is
   two).
3. **Tempids**: mint ident ids for new keyword values inside `wtxn`.
   A unique-identity tempid upserts to the entity holding its value in
   the committed AVET tree. A unique-identity claim whose value is a
   tempid or a lookup ref upserts once the value is known: a tempid
   bound by its own identity, a lookup ref found in the tree or naming
   an identity asserted anywhere in the same transaction; claims on an
   entity the transaction creates unify their tempids. Remaining tempids
   take eids from `sys/"eid"`, read once and bumped once; each must be
   the entity of some form, since a tempid only in value positions (or
   a map form holding nothing but `:db/id`) would name an entity with
   no datoms (`:nextomic/tx-data`). Two identities that bind one tempid
   to two entities are `:nextomic/conflict` on the first entity's
   attribute. A lookup ref names the committed holder of its `(a v)`,
   else the entity a unique assertion of the same tx-data puts `(a v)`
   on, wherever that assertion stands; otherwise it is
   `:nextomic/no-entity`.
4. **Expand**: a card-one assertion whose current value differs writes
   the retraction of the old value and the assertion of the new one in
   this `t`; asserting an already-current datom writes nothing; two
   different card-one values for one `(e a)` in one transaction, or an
   assertion and a retraction of the same datom in one transaction, are
   `:nextomic/conflict`. `[:db/retract e a]` retracts every current value
   of `a`. `[:db/retractEntity e]` retracts every current `(e a v)` from
   an EAVT `[e]` scan plus every current `(e' a' e)` from a VAET `[e]`
   scan, and the same for every component entity it holds, through
   component chains of any length. tx-data is a set: the two bare forms
   expand against the values current before the transaction, never
   against what the transaction asserts, so an assertion under the same
   `(e a)` stands whichever form comes first (`[[:db/add e :p/age 9]
   [:db/retract e :p/age]]` and its reverse both leave `9`), and an
   assertion of a value they retract is the same conflict as the
   explicit pair: re-asserting a current datom is a claim on it even
   though it writes nothing, so it and a retraction of that datom in one
   transaction, by any form and in either order, are
   `:nextomic/conflict`. Unique attributes are checked over the whole
   expansion, so a value moves between entities whichever form comes
   first: two entities asserting one unique `(a v)`, or an assertion of
   a `(a v)` another entity holds and the transaction does not retract
   (explicitly or by a card-one overwrite), is `:nextomic/unique`. Then
   `[tx-entity :db/txInstant now]` is appended as a datom of this
   transaction, unless the tx-data asserted `:db/txInstant` on
   `"datomic.tx"` itself: that instant stands, in the datom and in the
   txlog entry. Instants never go back: an asserted instant earlier
   than the previous transaction's is `:nextomic/tx-data`, and a clock
   behind it takes the previous instant. `:db/txInstant` on any other
   entity, or a retraction of one, is `:nextomic/tx-data`, since the
   txlog entry keeps each transaction's instant.
5. **Schema**: schema changes are ordinary assertions on attribute
   entities, checked here, and take effect for the transactions after
   the one that makes them (the data of the same transaction is
   expanded under the schema it began with). A new attribute needs
   `:db/valueType` and `:db/cardinality`. What may change afterwards:
   - `:db/valueType` never (`:nextomic/conflict`).
   - `:db/cardinality`: one → many always; many → one while no entity
     holds two values, in the tree or in the transaction, otherwise
     `:nextomic/schema` naming the attribute and an entity. The
     cardinality in force at each basis is kept (§4), so an as-of view
     reads sets or scalars as its time saw them.
   - `:db/index true` and `:db/unique` may be added, never retracted
     (`:nextomic/conflict`; an explicit `:db/index false` gives way to
     `true`), and the transaction that adds them backfills AVET from
     the current AEVT rows and `nx/avet-h` from the attribute's whole
     AEVT history, retractions included, so `index-range` and `datoms`
     over a history or as-of view find a value retracted before the
     index existed (an attribute becoming unique while two entities
     hold one value is `:nextomic/unique`). A unique attribute identifies one
     entity by one value, so it is cardinality one: `:db/unique` on a
     card-many attribute is `:nextomic/tx-data`, and a unique attribute
     becoming card-many `:nextomic/schema`.
   - `:db/fulltext true` may be added to a string attribute, never
     retracted (`:nextomic/conflict`; an explicit `false` gives way to
     `true`); on any other value type it is `:nextomic/schema`. The
     transaction that adds it backfills `nx/fulltext` from the
     attribute's current values, and from then on every assertion and
     retraction of one of its string values puts or deletes that
     value's token rows in the same write.
   - `:db/ident` on an attribute or ident entity renames it, provided
     the new keyword names nothing (`:nextomic/conflict` when it names
     another entity; asserting the entity's own ident is a no-op). The
     new ident wins everywhere and the old one is retired: the entity
     resolves by the new keyword alone, `ident`, `schema`, `entity`,
     `pull` and query results spell it the new way in every view, past
     or present, and the old keyword is `:nextomic/unknown-attribute`
     as an attribute, nil as an ident, and never minted again
     (`:nextomic/tx-data` when tx-data tries). The ident's id, its
     datoms and its keyword values are untouched, so the rename writes
     no datom; the transaction's entry holds only its `:db/txInstant`.
     An ident on a user-partition entity is `:nextomic/conflict`.
     An ident is never retracted, from an attribute or any other
     ident entity and by any form (`[:db/retract x :db/ident k]`, the
     bare `[:db/retract x :db/ident]`, a `:db/retractEntity`):
     `:nextomic/schema` naming it. Every datom's attribute and every
     keyword value is stored by the ident's id, so a name only moves,
     by a rename, and resolves the same way in `q`, `pull`, `entity`
     and tx-data before and after the refusal.
   - `:db/isComponent true` takes a ref attribute (`:nextomic/schema`
     otherwise) and may be set false again; `:db/doc` is an ordinary
     card-one attribute.
6. **Write**: for each assertion, put into the current trees (value
   `[t]`) and append `[.. top]` with `added = 1` to the history trees,
   an out-of-line value's payload as its `nx/eavt-h` value; for each
   retraction, delete from the current trees and append `added = 0` to
   the history trees. EAVT first, then AEVT, then AVET and VAET, each
   tree in the order §2.5 gives. Then `nx/txlog[t]`, then `sys`
   counters including `"t"`.
7. **Commit**: `wtxn.commit()`, after which the idents the transaction
   minted, renamed or read reach the connection's cache; until then
   they live in the transaction alone, since the write transaction
   sees its own uncommitted names. On any error `wtxn.abort()`: nothing
   partial can exist (emdb INV-SUB04), in the file or in the cache.
8. Return `{:db-before db :db-after db :tx t :tempids {..} :tx-data
   [[e a v t added] ...]}` with `db-after.basis = t`. `:tx` and the
   rows carry the transaction number `t`; the transaction entity is
   `2^46 | t`.

**Transaction functions.** A form `[:db.fn/call f arg ...]` calls `f`
during normalisation with `db-before` (a db-value at the connection's
basis, the state every function in the transaction sees) followed by
the args, and the tx-data it returns takes the form's place: it is
normalised like any other tx-data, so it may hold map forms, tempids
and further calls, in chains up to 1000 calls deep (`transact.max_call_depth`;
past it `:nextomic/tx-fn` names the limit). The bound stops a function
that calls itself forever long before the native stack would. `f` is
a function value, or a symbol naming a var resolved as a query
function is (§5); anything else is `:nextomic/tx-data`, and an unbound
symbol `:nextomic/tx-fn` naming it. A nil result is no tx-data. The
function value is called through `vm.callValue` and never stored: the
trees and the txlog hold only the datoms it returned. Its reads of
`db-before`, or of `(d/db conn)`, open ordinary read transactions
beside the held write; a `transact!`, `with` or `excise!` inside it, on
this connection or on another to the same file, is `:nextomic/nested`,
and a `db/*` write to the same file `:db/busy`, since the engine has one
writer. A throw inside it unwinds through the
native, aborts the transaction and reaches the caller's `try`. The
built-in `[:db.fn/cas e a old new]` asserts `new` on the
cardinality-one attribute `a` when the value the transaction sees (the
committed value, less what an earlier form of the same transaction
retracted) is `old`, nil meaning absent; otherwise it is
`:nextomic/cas` with `:attr`, `:expected` and `:actual`. `old` is only
matched, as a retraction's value is (step 2): a keyword the store has
never seen mints nothing and matches no value, so the cas fails with
`:expected` the keyword as the form wrote it. A card-many
attribute is `:nextomic/tx-data`. The assertion then follows the
card-one rule of step 4, so two cas forms on one `(e a)` in one
transaction conflict as two values would.

**Sync mode.** `:full` (default) syncs data and meta; `:no-meta`
batches the meta flush; `:none` is for bulk loads followed by
`(d/sync conn)`. A fully durable commit is two device flushes. Any
other `:sync` value is the VM's `:invalid-argument`.

---

## 4. Db-values and time

`(d/db conn)` opens a pooled read transaction, reads `sys["t"]` as the
basis, closes it, and returns `{store, basis, mode = current}`.

A connection counts its operations in flight (reads, a `transact!`, a
held `with`). `release` refuses while the count is nonzero
(`:nextomic/busy`); closing a connection at teardown while it is busy
marks it closed at once and frees the store when the last operation
ends, so no cursor in flight dangles. A released connection keeps its
struct for as long as db-values and entities can name it; every
operation through them, except an entity's `:db/id`, is
`:nextomic/closed`.

Every operation on a db-value opens one read transaction, reads
`sys["t"]` as `now`, and:

- **current mode**, `now == basis`: current trees, no fold. The common
  case: the program has not transacted since taking the db.
- **current mode**, `now > basis`: history trees with the as-of fold at
  `basis`. Correct, slower, and only reachable when the program itself
  transacts between taking a db and using it.
- `now < basis`: `:nextomic/basis-in-future`. Only possible after an
  engine-level rollback of the file; the db-value is dead.
- **as-of T**: history trees, fold over `top` with `t ≤ T`.
- **since T**: history trees, fold over `T < t ≤ basis`, from an empty
  state: an entity asserted before T and untouched since is invisible;
  a fact retracted after T shows nothing.
- **history**: history trees, every datom with `t ≤ basis`, no fold,
  each with its `added` flag. `history` composes with `as-of` and with
  `since` (`history ∘ since T`: every datom with `T < t ≤ basis`).
  `q` and `datoms` read a history view; `entity` and `pull` do not
  (`:nextomic/history-view`), since a map of current values has no
  meaning over retracted datoms.

A time argument `T` is a transaction number `t` (what a report's `:tx`
and its rows carry) or a transaction entity id `2^46 | t`; a negative
`T` is the VM's `:invalid-argument`.

**The fold** (`Store.FoldScan`). Walk from `setRange(prefix)` while the
key carries the prefix; consecutive keys with equal `(e a v)` form a
group in ascending `t`; keep the last `added` among datoms inside the
window; on group end emit the group's newest kept datom iff its `added`
is 1.

**Schema as-of.** `Schema` is built at the newest basis from the
history of the attribute partition: every assertion and retraction of
`:db/valueType`, `:db/cardinality`, `:db/unique`, `:db/index`,
`:db/isComponent` and `:db/fulltext` on an attribute is one event of its
timeline. The cache serves a later basis while `sys["sg"]` is unchanged
and the txlog entries in between write no attribute-partition datom
(§2.3), and is rebuilt when another connection, of this build or an
older one, changed the schema. It
serves every earlier basis by replaying each attribute's timeline up to
it: attributes created after it are hidden, and every flag and the
cardinality read as that basis saw them, so an attribute indexed at one
`t` and made unique at a later one is indexed and not unique in a view
between them (`schema` shows it so, and a lookup ref on it is refused
there), and a component flag set false later still reads true, and
pulls the component whole, in a view before that.

The txlog is the change feed: `(d/tx-range conn from to)` scans
`nx/txlog` over `from ≤ t < to`; a bound that is `nil` or not given is
open.

**Excision.** `(d/excise! conn e)` removes every datom whose entity is
`e`, current and history, from all eight index trees;
`(d/excise! conn e attr)` those under one attribute. It is a
transaction: it takes the next `t`, its only datom is its
`:db/txInstant`, and everything happens in its one write transaction.
EAVT and EAVT-h lose the datoms by a prefix delete (AEVT and AEVT-h too
when the attribute is given), the other trees one key at a time from a
scan of the entity's history rows; the per-attribute counts drop by the
current rows removed. Every txlog entry that held one of the datoms is
rewritten without them and marked `{:excised [e ...]}`, the marker
accumulating across excisions; an emptied entry keeps its place, its
instant and its marker, and the excising transaction's own entry
carries the marker too, so `tx-range` replays the same transactions
with the datoms gone. Every view is affected alike, a db-value taken
before the excision included, since the trees are the only record.
Datoms that refer to `e` through a ref attribute are not its datoms and
stay. `e` is a user entity given as an eid, ident or lookup ref; an
attribute, ident or transaction entity, or a tempid, is
`:nextomic/tx-data`, an unallocated id `:nextomic/no-entity`. An entity
excised of everything stays addressable, and excising it again removes
nothing. Inside a `with` or a transaction function, `excise!` is
`:nextomic/nested`.

---

## 5. Query pipeline

`q` is a native. Input is a query value (vector or map form) plus the
db and inputs.

**Parse** → IR `{find, in, where, rules}` with a symbol table; a syntax
error throws `{:error :nextomic/query-syntax :message "..." :clause i}`
with the clause index when the error is inside `:where`; clauses nested
past the native stack guard are the catchable `:stack-overflow`. The IR
is pure syntax, so it is cached per VM by query value (a hit is the
same value, or one `=` to it with lists and vectors told apart at every
depth) and reused across every db and basis; the rule set bound to `%`
is cached the same way. A parse borrows from its query, so the VM's
root walk marks every query value a cache holds (`docs/GC.md` §3); each
cache holds at most 128 parses, and on a miss replaces the least recently used one no
running query is using (`natives.State`). Constants in data patterns
are encoded to their sortable bytes, and lookup refs and idents in
constant positions resolve against the db, at plan time. `:in` inputs resolve
by the role their variable plays in `:where`: one bound in an entity
position, or in the value position under a constant ref attribute, may
be a lookup ref or an ident and becomes its eid (one that names nothing
matches nothing, so its row is dropped; a lookup ref whose value has the
wrong type is `:nextomic/value-type`); one in the value position under
a keyword-valued attribute stays a keyword.

**Plan** → ordered steps. Index choice by what is bound when the clause
runs:

| bound | index | cost estimate |
|---|---|---|
| `e` | EAVT `[e][a?]` | attributes per entity |
| `a` + `v`, unique | AVET `[a][v]` | 1 |
| `a` + `v`, indexed | AVET `[a][v]` | entries of `a` / 16 |
| `a` + `v`, not indexed | AEVT `[a]` + filter | entries of `a` |
| `v` ref, `a` optional | VAET `[v][a?]` | small |
| `a` only | AEVT `[a]` | entries of `a` |
| `a` a bound variable (id or ident) | AEVT `[a]` + filter | entries / attributes |
| `v` only, not a ref | AEVT, every datom + filter | entries of AEVT |
| nothing | refused (`:nextomic/unbound-pattern`) | |

A value with no attribute is an entity id when it can be one: an
integer, a lookup ref, or a variable at plan time. `[?e _ 41]` finds the
datoms that refer to entity 41 through VAET, never a long attribute
holding 41. A variable whose cell turns out to be a string, keyword,
double or boolean falls back at run time to the scan of every datom.
That scan costs the whole database and is the price of `[?e _ ?v]`
without an attribute; give the attribute when it is known. A constant
that cannot exist in the store (an unknown ident, a lookup ref with no
entity, a value of the wrong type for the attribute) makes its scan
unsatisfiable: it yields nothing and is not an error.

Clauses are ordered greedily by estimate given the variables bound so
far; predicates run at the first point all their variables are bound.
A clause's estimate is taken once and again only after one of its own
variables is bound, and membership in the bound set is a lookup, so
ordering n clauses takes O(n) estimates and O(n²) constant-time
checks.
A pattern that binds no new variable (`[?e :tags _]` with `?e` bound)
is an existence test: its seek stops at the first matching datom.
An `or` costs the sum over its branches of each branch's cheapest
pattern; a call to a non-recursive rule the same over the rule's
bodies, with the head variables bound where the call's arguments are
(16 for a body with no pattern that can run); a call into a recursive
rule runs after every pattern that could bind its arguments.
Join per step: index nested loop (seek per row) when `rows × log n` is
below four times the scan estimate, otherwise one scan of the constant
prefix hash-joined on the shared variables (`plan.nestedLoop`); a
pattern that takes nothing from the row is always that one scan, joined
as a cross product, since every row would read the same datoms. The
constant-prefix scan runs once per query for each source, index and
shape of its positions (which hold constants, which a variable, which
repeat one), and a later pattern of that shape joins with the same rows
under its own variables. The hash side is the smaller one, or the
cached scan, which keeps its indexes for the next join with it; an
index is chained by row hash and sized up front. The joined rows are
gathered column by column from the two sides, and a side whose every
row comes through once, in order, lends its columns instead.
Estimates come from `treeStat` and per-attribute counts kept in
`Schema`.

After ordering, a liveness pass gives each step the variables the
relation drops after it: every variable no later step reads and the
plan's caller does not ask for. The query's caller asks for its
`:find` and `:with` variables, a `not` for its join variables, an `or`
branch for the `or`'s join variables, a rule body for the rule's head.
A variable only a predicate, a function, a `not` or an `or-join` reads
is dropped once that clause has run, so a relation holds the variables
still in use rather than every variable bound so far: an n-clause chain
`[?x0 :next ?x1] ... [?xn-1 :next ?xn]` finding `?x0 ?xn` keeps two
columns between steps, not n. A variable only the caller asks for,
which no later step reads, is still carried; once four such are held
with two steps still to run, the relation parks them: they leave it for
one column of row numbers into the rows that held them (the previous
park's column among them), and the plan's end puts them back. The same
chain finding every `?xi` then carries at most five columns, and its
cost grows with the rows times the clauses, not times their square.
`explain` ends a step's line with the variables dropped after it (`drop
?x1`) and the ones it parks (`park ?x0 ?x1 ?x2 ?x3 -> ?row`).

**Sources.** A query without `:in` reads `[$]`. `:in` binds data
sources, `$` or any `$name` (`:in $db ?x`), positional like every
input; a source input that is neither a db value nor a collection is
`:kind-mismatch`.

- **A db value** may name another connection or a time view of the
  same one. Each is one read transaction for the whole query;
  attributes, idents, lookup refs and keyword values resolve per source,
  and an input in an entity role resolves in the source of the first
  pattern that gives it that role.
- **A vector, list or set of tuples**: a pattern matches its tuples by
  position (`[e a v tx added]`; a tuple shorter than a position the
  pattern uses matches nothing), compares constants as written (a
  keyword is never read as an ident) and joins like any pattern, rule
  bodies included. A lookup ref, a `missing?`, `get-else`, `get-some`
  or `fulltext` call, or a pull expression on a collection is
  `:nextomic/query-syntax`; an element that is not a tuple
  `:nextomic/value-type`.
- **No source**: `(d/q '[:find ?x :in [?x ...] :where [(odd? ?x)]] [1 2
  3])` is `#{[1] [3]}`. The query runs over its inputs alone, and a
  pattern, a `missing?`, `get-else`, `get-some` or `fulltext` call, or
  a pull expression in it is `:nextomic/query-syntax`.

A data pattern, a `missing?` or `get-else` call, or a rule call
prefixed with a source reads it: `[$2 ?e :a ?v]`, `[(missing? $2 ?e
:a)]`, `($2 rule ?x)`. An unprefixed clause reads the first source, and
so does `$`, whatever `:in` calls it. A rule body writes `$` or nothing
and reads the source its call names, so one rule set serves every
source; a recursive component runs under one source. A clause naming an
undeclared source is `:nextomic/query-syntax`.

**Execute** over one read transaction per source for the whole query
(one snapshot for every cursor, emdb INV-T02). Scans drive
`openCursorForTree` + `setRange` with the §4 fold inline; constants in
the prefix narrow the seek, constants after an unbound position filter.
The built-ins are Zig over cells:

- predicates `<`, `<=`, `>`, `>=`, `=`, `not=` (`!=` is `not=`) and
  `missing?`; with a binding form, `[(< ?a ?b) ?lt]`, one binds its
  boolean instead of filtering;
- `ground`, `tuple`, `untuple`;
- `get-else`, which takes a cardinality-one attribute and a default
  that is not nil (`:nextomic/query-syntax` otherwise; a card-many
  attribute or a nil default written as a constant is refused when the
  query is planned, with its `:clause`, one bound to a variable when
  the clause runs);
- `get-some`, which binds `[attr value]` for the first of its
  attributes the entity has and drops the row when it has none;
- `fulltext` (below).

An attribute `missing?`, `get-else` or `get-some` names that does not
exist is `:nextomic/unknown-attribute`. Numbers compare as `compare`
orders them: two integers exactly at any size (a long, a bignum input
past i64), an integer and a double in f64. Strings compare by their
bytes and keywords as `compare` orders them (an unqualified keyword
before any qualified one, then by namespace, then by name); a
comparison across other types (a string against a number, a number
against a keyword) or of any other value (a vector) is
`:nextomic/value-type`, as is an input or a
function result whose shape does not fit its binding form. Any other
symbol resolves through the namespace registry as the compiler resolves
it (an alias-qualified `ns/name` to that namespace's own var, a bare
name in the current namespace and then its auto-referred parents) and
is called with `vm.callValue`; an unbound name throws
`:nextomic/query-syntax` naming it. A throw inside the function unwinds
through the native, the read transaction closes, and the thrown value
reaches the caller's `try`; `ControlTransferred` propagates unchanged.
Function position also takes a variable, `[(?pred ?x)]` or `[(?f ?x)
?y]`: it is an input of the clause, bound through `:in` or an earlier
clause (so a rule head may carry it), and the value it holds is applied
when the clause runs: a function through `callValue`, a keyword or
collection as the language applies them, anything else is the VM's
`:not-callable`. A function is identity-valued in a relation. The `q`
hook roots every user-function result for the query's life, and every
heap value the pipeline builds before the result (a `tuple` or
`fulltext` result bound as one value, an aggregate's vector or set;
`docs/GC.md` §11.5).

**fulltext.** `[(fulltext $ :attr "needle") [[?e ?v]]]` binds, for a
string attribute carrying `:db/fulltext` at the view's basis, every
`[e v]` whose value holds every token of the needle, in entity order;
the attribute and the needle may be variables bound earlier or by
`:in`. Tokens are the runs of ASCII letters, digits and non-ASCII
bytes, split on every other byte, each character folded by Unicode
simple case folding (`CaseFolding.txt`, statuses C and S) for ASCII,
Latin (Latin-1, Extended-A, the regular pairs of Extended-B, Extended
Additional), Greek and its extended block, Cyrillic, Armenian,
Georgian, Glagolitic, Deseret and the letterlike, Roman numeral,
circled and fullwidth forms, so `Café`, `CAFÉ` and `café` are one
token, as are `ΣΟΦΙΑΣ` and `σοφιας`; a byte that is not UTF-8 stays as
it is, and no accent or normalization is removed. A folded run longer
than 255 bytes is not a token, and a needle without tokens matches
nothing. Indexing and search fold through one tokenizer. The plain view
at the newest basis intersects the `nx/fulltext` rows of the tokens
when they are current (§2.3 `"ft"`), then reads the matching values
from EAVT; an as-of, since or history view, or one over stale rows,
re-tokenises the attribute's values under that view, so it answers
with the values its time held.
An attribute without `:db/fulltext` at the basis is `:nextomic/tx-data`
naming it; an unknown one `:nextomic/unknown-attribute`; a needle that
is not a string `:nextomic/value-type`.

**Aggregates** group the basis set (the distinct tuples over the `:find`
and `:with` variables) by the plain find elements: `count`, `sum`,
`avg`, `min`, `max`, `median`, `variance`, `stddev`, `count-distinct`,
`distinct` (a set), `(min n ?x)` and `(max n ?x)` (the n smallest or
largest, a vector), `(sample n ?x)` (up to n distinct values, a vector)
and `(rand n ?x)` (n values with repetition, a vector). `min` and `max`
take any type, in the cell order: nil, booleans, numbers, strings,
keywords as `compare` orders them, then other values in a stable
order; `sum`, `avg`, `variance` and `stddev` take numbers, bignums
included (`:nextomic/value-type` otherwise), and a `sum` of integers
is exact at any size, a bignum past the fixnum range as `+` gives;
`median` of an odd count is the middle value of any type, of an even
count the mean of the two middle numbers as a double;
`variance` divides by the count (population variance) and `stddev` is
its square root. Any other symbol in aggregate position,
`(my.ns/total ?x)`, is a custom aggregate: it resolves like a function
clause and is called with the vector of the group's values. No rows
form no group, so an aggregate-only query over nothing is empty (nil
for `.` and `[...]`), not zero.

**Relation** is a Zig-private columnar struct in the query arena
(`vars`, typed columns for eids and longs, a `Value` column otherwise);
never a VM value, and never changed once built, so a relation made
from another shares the columns it keeps (dropping a variable copies
nothing). Results are copied into the VM heap as a persistent
set of vectors (or the `.`, `[...]`, `[[...]]` find specs). A find
element `(pull ?e pattern)` or `(pull $src ?e pattern)` (a pattern
vector, §6.2, or a variable a scalar `:in` input binds to one) groups
and dedups as `?e` and is applied when the result is copied, in the
query's own snapshot of the source it names (`$` by default): the
pattern's map, nil for an entity with no datoms, `:nextomic/value-type`
when `?e` is not an entity id, `:nextomic/pull-syntax` for a bad
pattern, `:nextomic/history-view` on a history db. `:keys`, `:strs` or
`:syms` name every find element (one symbol each, relation find spec
only) and the result is a vector of maps under those names as keywords,
strings or symbols.

**Rules.** `:in $ %` binds a rule set. Rules of one name share one
arity and one required count, and every call to a rule, in the query or
inside a rule body, passes that many arguments
(`:nextomic/query-syntax` otherwise). A call to a non-recursive rule
inlines the rule's bodies, renamed afresh for that call, as the
branches of an `or-join` over its arguments. Recursive rules run
semi-naive: `total = base bodies; delta = total; repeat { new = ∪ bodies
with one recursive call bound to delta, others to total, minus total;
total ∪= new; delta = new } until delta is empty`. The fixpoint only
adds rows, so it answers stratified rules only: a recursive component
whose rules call one another inside a `not` is `:nextomic/query-syntax`
naming the rule. `not`/`not-join` are anti-joins on the shared
variables; `or`/`or-join` are unions of sub-plans with the same output
variables (every branch's rows go into one set, each row hashed once),
and an `or-join` whose join vector leads with a group,
`(or-join [[?a] ?b] ...)`, runs only once the group's variables are
bound.

---

## 6. Lisp API (`nextomic` namespace, conventionally `d`)

An entity argument `e` follows one contract in every native: an eid,
an ident, or a lookup ref `[attr v]`. An eid below 1 is
`:nextomic/no-entity`; a lookup ref on a non-unique attribute, or a
vector that is not `[attr v]`, is `:nextomic/tx-data`; a lookup value
of the wrong type is `:nextomic/value-type`; any other kind is the VM's
`:kind-mismatch`. An ident or lookup ref that names nothing is nil from
`entid` and `entity`, matches nothing in `datoms`, and is
`:nextomic/no-entity` from `pull`.

| form | semantics |
|---|---|
| `(d/connect path)` / `(d/connect path {:sync ...})` | open or create, making the parent directories, bootstrap on first open, cache idents and schema; returns a connection. A complete store opens without writing, read-only when the file is (§2); `:db/map-full` only when the file cannot grow |
| `(d/release conn)` | close, idempotent; `:nextomic/busy` while an operation on the connection is in flight (§4) |
| `(d/db conn)` | db-value at the current basis |
| `(d/basis-t db)` | the basis |
| `(d/transact! conn tx-data)` / `(d/transact! conn tx-data {:sync ...})` | §3; returns the report. tx-data forms: `[:db/add e a v]`, `[:db/retract e a v?]`, `[:db/retractEntity e]`, `[:db.fn/call f arg ...]`, `[:db.fn/cas e a old new]` and map forms |
| `(d/entity db e)` | a lazy entity (§6.1); nil when `e` has no datoms in this view; `:nextomic/history-view` on a history db |
| `(d/touch ent)` | the map `{:db/id e :attr v ...}` of every attribute read in one pass, card-many as sets, refs as eids; `{:db/id e}` alone when the view holds no datom of `e` (a ref to an excised entity) |
| `(d/entity-db ent)` | the db-value the entity reads through |
| `(d/entid db x)` / `(d/ident db x)` | lookup ref or ident → eid; eid → ident |
| `(d/datoms db index c1 ... tx added)` | vector of `[e a v t added]` after the fold. `index` is `:eavt`, `:aevt`, `:avet` or `:vaet` (another keyword is `:invalid-argument`); its components follow in index order, then `tx` (a t or a transaction entity id) and `added` (a boolean); nil leaves one unbound, later ones filter |
| `(d/index-range db attr start end)` | the AVET datoms of an indexed or unique attribute with `start <= v < end` in value order; a nil bound is open; another attribute is `:nextomic/tx-data` naming it, a bound of the wrong type `:nextomic/value-type`. The cursor seeks to `start` and stops at `end`; the range test compares decoded values, so long strings and byte arrays (§2.2) are placed by value: a bound of 64 bytes or more seeks at its 64-byte prefix class, which is scanned whole |
| `(d/q query & inputs)` / `(d/q {:query query :args [inputs...]})` | §5, inputs positional to `:in`; the arg-map is the same call; Datomic's `:timeout` and `:io-context` keys are accepted and ignored (a query is one read in the caller's thread, with no timer to arm and no I/O to attribute), and any other key is `:nextomic/query-syntax`. `:find` takes `.`, `[...]`, `[[...]]`, aggregates and pull expressions, with `:keys`/`:strs`/`:syms` and `:with`; `:where` takes patterns, predicates, function bindings, `not`/`not-join`/`or`/`or-join`/`and` and rule calls. A relation query returns a persistent set of vectors, or a vector of maps under `:keys` |
| `(d/explain query & inputs)` / `(d/explain {:query query :args [...]})` | the plan `q` would run, as an aligned table: one numbered line per step with its description (index, estimate, tree size, source when not `$`, bound variables marked `!`, or `unsatisfiable`), the join the step runs (`nested`, one seek per input row; `hash`, one scan of the constant prefix hash-joined on the shared variables; `fixpoint` for a recursive rule; `none` for an unsatisfiable scan) and the estimated rows after the step; sub-plans indent under their step and end with `rows~` |
| `(d/as-of db t)` / `(d/since db t)` / `(d/history db)` | new db-values (§4) |
| `(d/excise! conn e)` / `(d/excise! conn e attr)` | §4 "Excision"; returns the recording transaction's report plus `:excised [e]` and `:removed`, the count of history rows that went |
| `(d/tx-range conn)` / `(d/tx-range conn from)` / `(d/tx-range conn from to)` | vector of `{:t t :instant i :data [...]}` for `from ≤ t < to`, oldest first, with `:excised [e ...]` on an entry an excision touched; a bound that is `nil` or not given is open |
| `(d/schema db)` | map ident → `{:db/id :db/ident :db/valueType :db/cardinality :db/index :db/isComponent :db/fulltext}`, plus `:db/unique` and `:db/doc` when the attribute has them in this view; every flag as the view's basis saw it (§4 "Schema as-of") |
| `(d/pull db pattern e)` | the pattern's map (§6.2); nil when the entity has no datoms in the view. Defined on current, as-of and since views; one read per call |
| `(d/pull-many db pattern es)` | one result per entity of the vector or list `es`, in its order, in the same read |
| `(d/with conn tx-data f)` | speculative transaction: tx-data applied in a held write transaction, `f` called with `db-after` (a db-value over the uncommitted state: `q`, `entity`, `pull`, `datoms`, `schema` and the time views read it) and the report `transact!` would have returned, then aborted. Returns `f`'s value; a throw inside `f` propagates after the abort; the committed basis is unchanged and the next `transact!` takes the same `t`. `transact!`, `with` and `excise!` inside the scope are `:nextomic/nested`; `db-after` after the scope is `:nextomic/closed` |
| `(d/sync conn)` | `Env.sync()` after `:none` loads |
| `(d/with-conn [c path opts?] body...)` | macro: connect for the extent of body; released on every exit, a throw keeps propagating |

A connection prints as `#nextomic/conn "path"`, a db-value as
`#nextomic/db {:basis-t 7 :mode :current}` (`:as-of`, `:since`,
`:history` with their bounds), an entity as `#nextomic/entity {:db/id
4294967296}`: the eid alone, since the attributes are read on access
and `touch` prints them. A connection is identity-valued; db-values
are values, equal when they read the same file (by device and inode,
as §2 tells files apart), basis and mode, whichever connection to the
file they came through, and hash accordingly: every connection to one
file shares its environment and its `t`, so one basis and mode name
the same datoms through any of them, as Datomic's peer hands every
`connect` to one database the same connection. The view of a
speculative `with` reads uncommitted datoms at a `t` a later commit
reuses, so its db-values equal only its own. Entities are values,
equal when their db-values are equal and their eids agree, and hash
accordingly.

Schema install is `transact!` of attribute entities: `{:db/ident
:user/email :db/valueType :db.type/string :db/cardinality
:db.cardinality/one :db/unique :db.unique/identity :db/index true}`;
what a later transaction may change is §3 step 5.

There is no datom heap kind: a datom is the vector `[e a v t added]`
every read returns.

### 6.1 Lazy entities

`(d/entity db e)` is a value of the `nextomic_entity` kind holding the
db-value and the eid; one read resolves `e` and confirms a datom.

- `(:attr ent)`, `(get ent :attr default)` and `(contains? ent :attr)`
  open one read at the entity's basis and mode and fold that attribute:
  a card-many value is a set, a ref is a lazy entity of the same
  db-value, so `(:addr/city (:person/home ent))` navigates and
  `(map :db/id (:person/friends ent))` names the referents.
- An attribute the entity lacks, an unknown attribute or a non-keyword
  key yields the default (false for `contains?`). `(:db/id ent)` is the
  eid and opens nothing.
- `(keys ent)`, `(vals ent)`, `(seq ent)` (entries as `[k v]`),
  `(count ent)` (attributes plus `:db/id`) and `(into {} ent)` read
  every attribute in one pass, refs as entities.
- Reverse refs (`:ns/_attr`) belong to `pull`: an entity has none.
  `(map? ent)` is false; `assoc`, `dissoc` and `find` take the map
  `touch` returns.
- The db-value is fixed, so a later transaction never changes what an
  entity reads. Equality is by db-value and eid (§6), so
  `(= (:person/home ent) (d/entity db (:db/id (:person/home ent))))`
  holds and entities of views that differ are not equal.

### 6.2 Pull patterns

```
pattern = [spec+]
spec    = attr | * | "*" | {key sub} | (attr opt+) | [attr opt+]
key     = attr | (attr opt+) | [attr opt+]
attr    = :ns/name | :ns/_name        ; reverse: the entities pointing here through name
opt     = :limit n | :limit nil | :default v | :as key
sub     = pattern | ... | depth
```

`(limit attr n)` and `(default attr v)` are accepted as well; `:as`
takes any value as the key. `:db/id` is always present; a missing
attribute is omitted unless it has a default; explicit specs win over
`*` for the attributes they name. Card-many values are vectors in index
order cut at 1000 unless `:limit` says otherwise (`*` cuts at 1000
too). A reverse attribute is a vector of referrers, except through a
component attribute, whose one owner is pulled with `[*]`. A ref is
`{:db/id e}` plus `:db/ident` when it has one, unless the spec names a
sub-pattern; a component target is pulled with `[*]`. `...` or a depth
re-applies the enclosing pattern to the target; a target already on the
path, or past the depth, is a plain ref, and a walk or a pattern nested
past the native stack guard is the catchable `:stack-overflow`, never a
crash. A bad pattern is `:nextomic/pull-syntax` with the spec's index
as `:clause`.

---

## 7. Errors

Every error is catchable. An error that can say more travels as a map,
`{:error keyword ...}`, whose other keys name what went wrong; one that
cannot is the bare keyword. The map is what `catch` receives; `(:error
m)` is the keyword. A key is present only when its value is known.

| error | when | payload |
|---|---|---|
| `:nextomic/unknown-attribute` | an attribute keyword or id names no attribute | `:attr`, as the program wrote it |
| `:nextomic/value-type` | a value that does not fit its attribute's type, or a comparison or aggregate over a type it does not take | bare |
| `:nextomic/unique` | two entities would hold one unique `(a v)` | `:attr` and `:value` |
| `:nextomic/conflict` | two claims in one transaction disagree, or a schema change §3 step 5 refuses as a conflict | `:e` and `:a` |
| `:nextomic/no-entity` | an entity reference names nothing, or an id no allocator handed out | bare |
| `:nextomic/unbound-pattern` | a pattern with nothing bound | bare |
| `:nextomic/basis-in-future` | a db-value newer than its file (§4) | bare |
| `:nextomic/closed` | an operation through a released connection or an ended `with` scope | bare |
| `:nextomic/busy` | `release` while an operation is in flight | bare |
| `:nextomic/tx-data` | malformed tx-data, a lookup ref on a non-unique attribute, a nested map nothing could reach, a value-only tempid, a unique card-many attribute, `fulltext` or `index-range` on an attribute without the flag | `:message`; `:attr` when an attribute is at fault |
| `:nextomic/schema` | a schema change the attribute's data or type refuses, or the retraction of an ident | `:message` and `:attr`; `:e`, the entity holding two values, when many → one is refused |
| `:nextomic/history-view` | `entity` or `pull` on a history db | bare |
| `:nextomic/nested` | `transact!`, `with` or `excise!` while the file's write transaction is held (a `with` scope, a transaction function, another connection to the same file) | bare |
| `:nextomic/tx-fn` | a transaction function that cannot run | `:message`: the unbound symbol, or the depth limit and its value |
| `:nextomic/cas` | a `:db.fn/cas` whose expectation failed | `:attr`, `:expected` and `:actual`, the last two nil for an absent value |
| `:nextomic/query-syntax` | a query the parser or planner refuses, or an unbound function name at run time | `:message`; `:clause`, the index into `:where`, when inside a clause. A scoping refusal names the variable at fault: the one an `or` branch mentions and another does not, the join variable an `or-join` branch or a rule body leaves unbound, the one a `not` body has that nothing outside binds, the argument, function-position, `not-join` or required `or-join` variable no clause ever binds |
| `:nextomic/pull-syntax` | a bad pull pattern (from `pull`, `pull-many` or a find element) | `:message`; `:clause`, the index of the spec |
| `:kind-mismatch`, `:invalid-argument`, `:arity-mismatch` | the VM's own keywords for an argument of the wrong kind (a db-value where a connection belongs), an unknown index, `:sync` option or a negative `t`, or a wrong argument count | bare |
| `:stack-overflow` | tx-data, a query or a pull pattern nested past the native stack guard | bare |
| `:db/*` | an engine failure, through `db.failureName` (`:db/key-too-large`, `:db/map-full`, `:db/read-only`, `:db/open-failed`, ...); a store whose bytes do not decode, or name an ident it lacks, is `:db/corrupted` | bare |

---

## 8. Module layout

```
src/nextomic/
  root.zig       module root; re-exports
  key.zig        sortable encodings, index key pack/unpack, prefix successor
  datom.zig      Datom, txlog entry codec
  store.zig      Env ownership, 12 TreeIds, bootstrap, sys counters, raw put/del/scan, FoldScan
  idents.zig     durable keyword <-> id, per-connection cache
  schema.zig     Schema from attribute datoms as-of a basis, per-attribute counts
  transact.zig   §3
  excise.zig     §4 "Excision": the tree deletes and the txlog rewrite
  fulltext.zig   the case-folding tokenizer and the nx/fulltext rows: put, delete, search, rebuild
  db.zig         Conn, DbValue, datoms, entity, entid/ident, tx-range
  handle.zig     heap bodies of the three value kinds (its own build module)
  marshal.zig    VM values to and from datom values: the entity, value and cell contracts
  relation.zig   columnar Relation and its Cell
  pull.zig       §6.2
  query.zig      q and explain over parse, plan and exec; the data sources
  query/ir.zig   the parsed query and rule set
  query/parse.zig  query value to IR; the rooted, bounded parse caches
  query/plan.zig   greedy ordering, index choice, explain
  query/exec.zig   scans, matches over collections, built-ins, aggregates, materialising
  query/rules.zig  rule expansion, the stratification check, the semi-naive fixpoint
  query/natives.zig  q and explain (and their arg-map form), the call hook
  natives.zig    nextomic/* NativeFn table, error mapping, per-VM state, install
src/stdlib/nextomic.nx   sugar only (with-conn)
bench/nextomic.zig       the `nextomic` bench category (docs/PERF.md §3.7)
```

`src/nextomic/` sits above `dispatch` and `vm` in the one runtime
module (`src/root.zig`), and only `stdlib` imports it; `cli` installs
it through `stdlib.installNextomic` and bootstraps `stdlib/nextomic.nx`
with the `nextomic` namespace current. Nextomic never uses the `db/*`
layer's connections, tree opens or codec-encoded keys: it holds raw
`*emdb.Txn` handles and byte keys over its own `Env` (§2) and shares
with `db.zig` only the geometry constants and `db.failureName`.

Value kinds `nextomic_conn`, `nextomic_db` and `nextomic_entity` are
heap boxes from `handle.zig`, which `dispatch`, `format`, `gc` and `vm`
import without the rest of Nextomic. The connection box (the `Conn` the
VM owns on `vm.nextomic_connections`, and the path text) and the db box
(that pointer, the file's device and inode, basis and mode) are
collector leaves; the entity box
holds its db box, the eid, the read hook and the map of its last full
read, and the collector marks the db box and that map (`docs/GC.md`
§5). `vm.lookup` reaches the hook for `(:attr ent)` and `get`; the
`stdlib` arms for `contains?`, `keys`, `vals`, `seq`, `count`, `empty?`
and `into` call `natives.entityHas` and `natives.entityMap`.

Tests: `test/prop/nextomic_key.zig` (encoded order equals value order
per type, longs over all of i64 and its edges) and
`test/prop/nextomic_tx.zig` (random transactions against an in-memory
model, at every basis); the corpora
`test/integration/nextomic_q.zig` and `nextomic_pull.zig` against naive
evaluators over the shared fixture `nextomic_fx.zig`;
`nextomic_fn.zig` (transaction functions, cas, schema alteration,
excision, full-text) and `nextomic_entity.zig` (the lazy entity through
the pipeline and under the collector's stress policy); and the
end-to-end scripts `test/nextomic/*.nx`, each diffed against its
`.out` by `zig build nextomic-nx`.

---

## 10. Where Nextomic wins, and where it does not

Wins, by construction: reads straight off the mapping with no
deserialization; empty-value index leaves; history as a range filter;
one file, one process, backup by transaction number. The measured
numbers are `docs/PERF.md` §3.7.

Queries scale with their clauses (§5): ordering n clauses takes O(n)
estimates, and a step costs its rows times the few columns still in
use, so a chain of n patterns over r rows costs O(n·r), whether its
`:find` names two variables or all of them. A 300-clause chain over a
100k-entity chain runs in under a second; a 1000-clause query plans in
a few milliseconds. What a step cannot avoid is its join: every step
of a long chain probes one hash index with every row it carries.

Not in scope: distribution (Datomic's peer/transactor split), a
cost-based optimizer beyond greedy selectivity, write-heavy OLTP beyond
one writer.

---

## 11. emdb: nothing required

The engine's public `Txn.txnId` field is not used: Nextomic's own `t`
is read from `sys` inside the same snapshot. Index trees carry only
`[t]` in current trees and nothing in history trees but an
out-of-line payload in EAVT-h, read with `Txn.getFromTree` on its
exact key or with a cursor seek to the fact's latest row. emdb
returns a value spanning several pages whole, from a cursor or a get,
assembled in the transaction's buffer and valid until that
transaction's next such read, so Nextomic copies what it keeps.

---

## 12. Differences from Datomic

- **An ident rename retires the old keyword in every view** (§3 step
  5): after `[:db/add :person/name :db/ident :person/full-name]` every
  view, an as-of view before the rename included, spells the attribute
  `:person/full-name`, and `:person/name` names nothing and is never
  minted again. Datomic keeps the old ident resolving beside the new.
- **A lookup ref may name an identity the same transaction asserts**
  (§3 step 3). Datomic resolves lookup refs against the database
  before the transaction only.
- **`:db/index true` and `:db/unique` are never retracted** (§3 step
  5), and `:db/unique` does not switch between identity and value.
  Datomic can drop an index or a uniqueness constraint.
- **`with` takes a connection and a function.** `(d/with conn tx-data
  f)` calls `f` with `db-after` and the report inside a held write
  transaction that is aborted when `f` returns, and returns `f`'s
  value; Datomic's `(with db tx-data)` returns the report.
- **`tx-range` takes the connection.** `(d/tx-range conn from to)`,
  either bound optional or nil, returns the entries as a vector of
  maps; Datomic's reads a log value.
- **Values are the VM's.** A long or an instant is an integer in i64,
  a fixnum or a bignum by its size (§2.2), and an instant is
  milliseconds as a long; Datomic takes a 64-bit long and a
  `java.util.Date`.
