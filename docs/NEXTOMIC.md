# NEXTOMIC.md — A Datomic-class database on nexis + emdb

This is the authoritative design for Nextomic: the storage layout, the
transaction protocol, the db-value semantics, the query pipeline and the
Lisp API. Code follows this document; when they disagree, fix one in the
same commit. The emdb-side view (what the engine already provides and
what must not be asked of it) is `../emdb/NEXTOMIC.md`. The reader's
introduction to Datomic and Nextomic is §1 of that file.

Nextomic requires **zero changes to emdb**. Every engine capability used
below is a public function or a committed invariant of emdb as it stands
(§11 lists the two places a wish was noted and the workaround chosen).

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
   are copied into the VM heap.

---

## 2. Store layout

Open with `emdb.EnvOptions{ .pageSize = 16384, .maxNamedTrees = 128 }`.
Page size is fixed for the file's life (emdb INV-M05) and sets the
4078-byte hard key bound; the Linux default would be 4K. All eleven
trees are opened in one bootstrap write transaction at connect and their
`TreeId`s cached for the connection's life (`treeNames` registration is
not thread-safe; nothing else is).

| tree | key | value |
|---|---|---|
| `nx/eavt` | `[e:6][a:4][v]` | `[t:6]` + full payload for out-of-line values |
| `nx/aevt` | `[a:4][e:6][v]` | `[t:6]` |
| `nx/avet` | `[a:4][v][e:6]` | `[t:6]` (indexed and unique attrs only) |
| `nx/vaet` | `[v:6][a:4][e:6]` | `[t:6]` (ref attrs only) |
| `nx/eavt-h` | `[e:6][a:4][v][top:6]` | empty, or the full payload |
| `nx/aevt-h` | `[a:4][e:6][v][top:6]` | empty |
| `nx/avet-h` | `[a:4][v][e:6][top:6]` | empty (indexed and unique attrs only) |
| `nx/vaet-h` | `[v:6][a:4][e:6][top:6]` | empty (ref attrs only) |
| `nx/txlog` | `[t:6]` | codec vector `[instant [e a v added] ...]` |
| `nx/idents` | `[0x00][utf8 text]` → id, `[0x01][id:4]` → text | |
| `nx/sys` | `"format"`, `"uuid"`, `"t"`, `"eid"`, `"aid"` | see §2.3 |

`top` = `(t << 1) | added`. `v` is always followed only by fixed-width
fields, so it is `key[prefix .. len - suffix]` with no length byte.

### 2.1 Identifiers

All ids are stored big-endian in 6 bytes and fit the VM's `fixnum`
(i48), so the usable range is `0 .. 2^47-1`.

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
are the same mechanism. They sort by id, not by text.

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

String order is UTF-8 byte order, which is code point order, not
UTF-16 order; no Unicode normalization is applied. Type tags never
compare equal across types, so `1` and `1.0` are different keys, in
line with `(= 1 1.0)` being false.

**Out-of-line values** (strings and byte arrays over 96 bytes): the
index key is an equality key, not an order key. A string or byte array
has one tag whatever its length, so byte order equals value order
across the threshold whenever two values differ within their first 64
bytes; two values that agree on those 64 bytes order by hash when
either is out of line. The decoder tells the shapes apart by the bare
`0x00`: an inline value ends there, an out-of-line value continues with
the `0x01` marker and the hash (the hash is two seeded xxh3-64 lanes).
Range predicates compare decoded values, never index keys, so they
are exact on long strings; only the index order of two long values that
share a 64-byte prefix is by hash. The full value is stored in the
`nx/eavt` value after the 6-byte `t` (and in `nx/eavt-h`); an AVET or
AEVT hit on a long value is confirmed by an EAVT point read before it is
returned. Two distinct values with the same 64-byte prefix and the same
128-bit hash under one `(e a)` are treated as one value; the probability
is 2^-128 and the rule is documented rather than defended against.

Worst-case key: AVET with a 96-byte string, `4 + 1 + 193 + 6 + 6 = 210`
bytes, inside emdb's 256-byte search-clue buffer.

### 2.3 `sys` tree

| key | value |
|---|---|
| `"format"` | u16 Nextomic format number (1) |
| `"uuid"` | 16 random bytes minted at bootstrap: the store id, stable across renames |
| `"t"` | u48 last committed logical transaction number |
| `"eid"` | u48 next user entity id |
| `"aid"` | u32 next attribute / ident id |

### 2.4 Bootstrap

The first open writes, with fixed ids so files from different builds
agree: the attributes `:db/ident`, `:db/valueType`, `:db/cardinality`,
`:db/unique`, `:db/index`, `:db/isComponent`, `:db/doc`,
`:db/txInstant`, and the idents `:db.type/{long double instant keyword
ref string uuid bytes boolean}`, `:db.cardinality/{one many}`,
`:db.unique/{identity value}`. Bootstrap is transaction `t = 1`.

---

## 3. Transactions

One `transact!` is one emdb write transaction. The VM is single-threaded,
so there is no queue; emdb's write lock is the transactor.

1. **Begin**: `wtxn = env.beginWriteWith(.{ .sync = opt })`;
   `t = sys["t"] + 1`.
2. **Normalise** tx-data to `[op e a v]` ops. tx-data is a vector or a
   list of forms; anything else, or a malformed form, is
   `:nextomic/tx-data` with a `:message`. Entities may be an eid, a
   tempid (string, or a negative fixnum), a lookup ref `[:unique/attr v]`,
   a keyword ident, or `"datomic.tx"` for the transaction entity. An
   explicit eid, as an entity or as a ref value, must have been handed
   out by its partition's allocator (a user id below `sys/"eid"`, an
   ident id below `sys/"aid"`, a transaction entity no newer than this
   transaction); any other id is `:nextomic/no-entity`, since it would
   collide with an id minted later. An allocated entity whose datoms
   were all retracted stays addressable. Attributes resolve through the
   ident cache (unknown → `:nextomic/unknown-attribute`); each `v` is
   converted by the attribute's `:db/valueType` (`:nextomic/value-type`
   when it cannot be). Map forms `{:db/id e :attr v ...}` expand, a map
   without `:db/id` being a fresh tempid. A nested map under a component
   attribute becomes an entity with a fresh tempid; under any other ref
   attribute it must name its entity with `:db/id` or a unique
   attribute, since nothing could reach it otherwise
   (`:nextomic/tx-data`). A reverse key `:ns/_attr` in a map form
   asserts `[x :ns/attr e]` for each `x` under it: `{:db/id e
   :user/_friends x}` makes `x`, an entity or a map form of one, point
   at `e`, and a vector of them is one referrer each; the attribute must
   be a ref. Vectors under card-many attributes expand to one datom
   each, except that under a ref attribute a two-element vector whose
   first element names an attribute is one lookup ref (`{:user/friends
   [:user/email "a@x"]}` is one friend; `[[:user/email "a@x"] "tmp"]` is
   two).
3. **Tempids**: mint ident ids for new keyword values inside `wtxn`.
   Resolve lookup refs and unique-identity tempids by an AVET probe
   **through `wtxn`** so datoms earlier in the same transaction are
   visible. A unique-identity claim whose value is a tempid or a lookup
   ref upserts once the value is known: a tempid bound by its own
   identity, a lookup ref found in the tree or naming an identity
   asserted anywhere in the same transaction; claims on an entity the
   transaction creates unify their tempids. A unique-value collision
   with a different entity is `:nextomic/unique`. Remaining tempids take
   eids from `sys/"eid"`, read once and bumped once.
4. **Expand**: a card-one assertion whose current value differs writes
   the retraction of the old value and the assertion of the new one in
   this `t`; asserting an already-current datom writes nothing; two
   different card-one values for one `(e a)` in one transaction, or an
   assertion and a retraction of the same datom in one transaction, are
   `:nextomic/conflict`. `[:db/retract e a]` retracts every current value
   of `a`. `[:db/retractEntity e]` retracts every current `(e a v)` from
   an EAVT `[e]` scan plus every current `(e' a' e)` from a VAET `[e]`
   scan, recursively through component attributes. Then
   `[tx-entity :db/txInstant now]` is appended as a datom of this
   transaction, unless the tx-data asserted `:db/txInstant` on
   `"datomic.tx"` itself: that instant stands, in the datom and in the
   txlog entry.
5. **Schema**: schema changes are ordinary assertions on attribute
   entities, checked here. A new attribute needs `:db/valueType` and
   `:db/cardinality`, and neither changes once written
   (`:nextomic/conflict`); `:db/index` and `:db/unique` may be added,
   and the transaction that adds them backfills AVET from AEVT (an
   attribute becoming unique while two entities hold one value is
   `:nextomic/unique`). A unique attribute identifies one entity by one
   value, so it is cardinality one: `:db/unique` on a card-many
   attribute is `:nextomic/tx-data`.
6. **Write**: for each assertion, put into the current trees (value
   `[t]`, plus the payload in `nx/eavt` for out-of-line values) and
   append `[.. top]` with `added = 1` to the history trees; for each
   retraction, delete from the current trees and append `added = 0` to
   the history trees. EAVT first in key order (append-biased splits),
   then AEVT, then AVET and VAET after sorting the batch (better leaf
   fill for random-order keys). Then `nx/txlog[t]`, then `sys` counters
   including `"t"`.
7. **Commit**: `wtxn.commit()`, after which the minted idents reach the
   connection's cache. On any error `wtxn.abort()`: nothing partial can
   exist (emdb INV-SUB04).
8. Return `{:db-before db :db-after db :tx t :tempids {..} :tx-data
   [[e a v t added] ...]}` with `db-after.basis = t`.

**Sync mode.** `:full` (default) syncs data and meta; `:no-meta`
batches the meta flush; `:none` is for bulk loads followed by
`(d/sync conn)`. A fully durable commit is two device flushes.

---

## 4. Db-values and time

`(d/db conn)` opens a pooled read transaction, reads `sys["t"]` as the
basis, closes it, and returns `{store, basis, mode = current}`.

A connection counts its operations in flight (reads, a `transact!`, a
held `with`). `release` refuses while the count is nonzero
(`:nextomic/busy`); closing a connection at teardown while it is busy
marks it closed at once and frees the store when the last operation
ends, so no cursor in flight dangles. A closed connection keeps its
struct for as long as db-values can name it; every operation on them
is `:nextomic/closed`.

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

A time argument `T` is a transaction number, or the entity id of a
transaction as the report's `:tx` and its `tx-data` rows carry it,
which names that transaction's `t`.

**The fold.** Walk from `setRange(prefix)` while the key carries the
prefix; consecutive keys with equal `(e a v)` form a group in ascending
`t`; keep the last `added` among datoms inside the window; on group end
emit the group's newest kept datom iff its `added` is 1.

**Schema as-of.** `Schema` is built from the attribute partition's
datoms with `t ≤ basis`, cached per `(store, basis)`; since schema is
additive, a cache built at a later basis is a superset and may serve an
earlier one for attributes that existed then.

The txlog is the change feed: `(d/tx-range conn from to)` scans
`nx/txlog` over `from ≤ t < to`; a bound that is `nil` or not given is
open.

---

## 5. Query pipeline

`q` is a native. Input is a query value (vector or map form) plus the
db and inputs.

**Parse** → IR `{find, in, where, rules}` with a symbol table; a syntax
error throws `{:error :nextomic/query-syntax :message "..." :clause i}`
with the clause index when the error is inside `:where`. The IR is pure
syntax over the VM's symbol table, so it is cached per VM by query value
(heap identity first, structural hash second) and reused across every
db and basis; the rule set bound to `%` is cached the same way. No
collector frees or moves a heap value, so a cache entry lives as long as
the VM; one that does must clear both caches. Constants in data patterns are
encoded to their sortable bytes, and lookup refs and idents in constant
positions resolve against the db, at plan time. `:in` inputs resolve
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
| `a` + `v`, indexed | AVET `[a][v]` | entries / distinct values |
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
without an attribute; give the attribute when it is known.

Clauses are ordered greedily by estimate given the variables bound so
far; predicates run at the first point all their variables are bound.
Join per step: index nested loop (seek per row) when `rows × log n` is
below the scan estimate, otherwise a hash join on the shared variables.
Estimates come from `treeStat` and per-attribute counts kept in
`Schema`.

**Sources.** `:in` starts with `$`; further `$name` bindings (`$2`,
`$hist`) take db values, positional like every input, and may name
another connection or a time view of the same one. A data pattern, a
`missing?` or `get-else` call, or a rule call prefixed with a source
reads it: `[$2 ?e :a ?v]`, `[(missing? $2 ?e :a)]`, `($2 rule ?x)`; an
unprefixed clause reads `$`. A rule body writes `$` or nothing and reads
the source its call names, so one rule set serves every source; a
recursive component runs under one source. Each source is one read
transaction for the whole query; attributes, idents, lookup refs and
keyword values resolve per source (an ident is an entity of the store
that holds it). An input in an entity role resolves in the source of the
first pattern that gives it that role. A clause naming an undeclared
source is `:nextomic/query-syntax`; a source input that is not a db value
is `:kind-mismatch`.

**Execute** over one read transaction per source for the whole query
(one snapshot for every cursor, emdb INV-T02). Scans drive `openCursorForTree` +
`setRange` with the §4 fold inline; constants in the prefix narrow the
seek, constants after an unbound position filter. Built-in predicates
(`< <= > >= = not= missing?`, later `ground tuple untuple get-else`) are
Zig over `Value`; an int and a double compare numerically, and a
comparison across other types (a string against a number, a number
against a keyword) is `:nextomic/value-type`, as is an input or a
function result whose shape does not fit its binding form. Any other symbol resolves through the namespace
registry as the compiler resolves it (an alias-qualified `ns/name` to
that namespace's own var, a bare name in the current namespace and then
its auto-referred parents) and is called with `vm.callValue`; an
unbound name throws `:nextomic/query-syntax` naming it. A throw inside
the function aborts the query, the read transaction closes, and the
thrown value reaches the caller's `try`; `ControlTransferred` propagates
unchanged. Function position also takes a variable, `[(?pred ?x)]` or
`[(?f ?x) ?y]`: it is an input of the clause, bound through `:in` or an
earlier clause (so a rule head may carry it), and the value it holds is
applied when the clause runs: a function through `callValue`, a keyword
or collection as the language applies them, anything else is the VM's
`:not-callable`. A function is identity-valued in a relation.

**Aggregates** group the basis set (the distinct tuples over the `:find`
and `:with` variables) by the plain find elements: `count`, `sum`,
`avg`, `min`, `max`, `median`, `variance`, `stddev`, `count-distinct`,
`distinct` (a set), `(min n ?x)` and `(max n ?x)` (the n smallest or
largest, a vector), `(sample n ?x)` (up to n distinct values, a vector)
and `(rand n ?x)` (n values with repetition, a vector). `min` and `max`
compare any type in the cell order; `sum`, `avg`, `variance` and `stddev`
take numbers (`:nextomic/value-type` otherwise); `median` of an odd
count is the middle value of any type, of an even count the mean of the
two middle numbers as a double; `variance` divides by the count
(population variance) and `stddev` is its square root. Any other symbol
in aggregate position, `(my.ns/total ?x)`, is a custom aggregate: it
resolves like a function clause and is called with the vector of the
group's values. No rows form no group, so an aggregate-only query over
nothing is empty (nil for `.` and `[...]`), not zero.

**Relation** is a Zig-private columnar struct in the query arena
(`vars`, typed columns for eids and longs, a `Value` column otherwise);
never a VM value. Results are copied into the VM heap as a persistent
set of vectors (or the `.`, `[...]`, `[[...]]` find specs). A find
element `(pull ?e pattern)` (a pattern vector, §6) groups and dedups as
`?e` and is applied when the result is copied, in the query's own
snapshot: the pattern's map, nil for an entity with no datoms,
`:nextomic/value-type` when `?e` is not an entity id,
`:nextomic/pull-syntax` for a bad pattern, `:nextomic/history-view` on a
history db. `:keys`, `:strs` or `:syms` name every find element (one
symbol each, relation find spec only) and the result is a vector of
maps under those names as keywords, strings or symbols.

**Rules.** `:in $ %` binds a rule set. Non-recursive rules inline as
sub-plans (cached per binding signature). Recursive rules run
semi-naive: `total = base bodies; delta = total; repeat { new = ∪ bodies
with one recursive call bound to delta, others to total, minus total;
total ∪= new; delta = new } until delta is empty`. `not`/`not-join` are
anti-joins on the shared variables; `or`/`or-join` are unions of
sub-plans with the same output variables.

---

## 6. Lisp API (`nextomic` namespace, conventionally `d`)

| form | semantics |
|---|---|
| `(d/connect path)` / `(d/connect path {:sync ...})` | open or create, making the parent directories, bootstrap on first open, cache idents and schema; returns a connection. The file starts as a 256 MB mapping and grows in 64 MB steps as it fills; `:db/map-full` only when it cannot grow |
| `(d/release conn)` | close, idempotent; `:nextomic/busy` while a query, pull, `transact!` or `with` on the connection is in flight (a released connection keeps its struct, so its db-values raise `:nextomic/closed`) |
| `(d/db conn)` | db-value at the current basis |
| `(d/basis-t db)` | the basis |
| `(d/transact! conn tx-data)` / `(d/transact! conn tx-data {:sync ...})` | §3; returns the report |
| `(d/entity db e)` | eager map `{:db/id e :attr v ...}`, card-many as sets, refs as eids; nil when the entity has no datoms in this view; `:nextomic/history-view` on a history db |
| `(d/entid db x)` / `(d/ident db x)` | lookup ref or ident → eid; eid → ident |
| `(d/datoms db :eavt e a v)` (index and optional components in index order; nil leaves one unbound, later ones filter) | vector of `[e a v t added]` after the fold |
| `(d/q query db & inputs)` | §5; `:find` with `.`, `[...]`, `[[...]]`, aggregates (built-in and custom) and `(pull ?e pattern)`, `:keys`/`:strs`/`:syms`, `:with`, `:in $ ?x [?x ...] [?x ?y] [[?x ?y]] % $2` with inputs positional after the db (a `$name` source takes a db value; `[$2 ?e :a ?v]` and `($2 rule ?x)` read it), `:where` with patterns, predicates, function bindings (a symbol or a bound variable in function position), `not`/`not-join`/`or`/`or-join`/`and`, rule calls; a relation query returns a persistent set of vectors, or a vector of maps under `:keys` |
| `(d/explain query db & inputs)` | the plan `q` would run, as a string: one numbered line per step with index, estimate, source (when not `$`) and bound variables |
| `(d/as-of db t)` / `(d/since db t)` / `(d/history db)` | new db-values (§4); `t` is a transaction number or a transaction's entity id |
| `(d/tx-range conn from to)` | vector of `{:t t :instant i :data [...]}` for `from ≤ t < to`, oldest first; a bound that is `nil` or not given is open |
| `(d/schema db)` | map ident → attribute map |
| `(d/pull db pattern e)` | the pattern's map for an eid, lookup ref or ident; nil when the entity has no datoms in the view. `e` follows the entity contract every native shares: an eid below 1, or an ident or lookup ref that names nothing, is `:nextomic/no-entity`; a lookup ref on a non-unique attribute, or a vector that is not `[attr v]`, is `:nextomic/tx-data`; a lookup value of the wrong type is `:nextomic/value-type`; any other kind is the VM's `:kind-mismatch`. A pattern is `[spec+]`: `*`, an attribute, `{attr sub-pattern}`, a reverse `:ns/_attr` (a vector of referrers; through a component, its one owner pulled with `[*]`), `{attr ...}` or `{attr depth}` recursion (a target already on the path, or past the depth, is a plain ref), `(attr :limit n)` / `(attr :limit nil)` / `(attr :default v)` / `(attr :as k)` and the `(limit attr n)` / `(default attr v)` spellings. `:db/id` is always present, a missing attribute omitted unless it has a default, card-many values are vectors in index order cut at 1000 unless `:limit` says otherwise (`*` cuts at 1000 too), a ref is `{:db/id e}` plus `:db/ident` when it has one, and a component target is pulled with `[*]`. Defined on current, as-of and since views; one read per call |
| `(d/pull-many db pattern es)` | one result per entity of the vector or list `es`, in its order, in the same read |
| `(d/with conn tx-data f)` | speculative transaction: tx-data applied in a held write transaction, `f` called with `db-after` (a db-value over the uncommitted state: `q`, `entity`, `pull`, `datoms`, `schema` and the time views read it) and the report `transact!` would have returned, then aborted. Returns `f`'s value; a throw inside `f` propagates after the abort; the committed basis is unchanged and the next `transact!` takes the same `t`. `transact!` and `with` inside the scope are `:nextomic/nested`; `db-after` after the scope is `:nextomic/closed` |
| `(d/sync conn)` | `Env.sync()` after `:none` loads |
| `(d/with-conn [c path opts?] body...)` | connect for the extent of body; released on every exit, a throw keeps propagating |

A connection prints as `#nextomic/conn "path"`, a db-value as
`#nextomic/db {:basis-t 7 :mode :current}` (`:as-of`, `:since`,
`:history` with their bounds). A connection is identity-valued; db-values
are values, equal when they name the same connection, basis and mode.

Schema install is `transact!` of attribute entities: `{:db/ident
:user/email :db/valueType :db.type/string :db/cardinality
:db.cardinality/one :db/unique :db.unique/identity :db/index true}`.

Later: transaction functions, `:db.fn/cas`, excision, lazy entities,
full-text, a datom heap kind.

---

## 7. Errors

All errors are keywords in the `nextomic` namespace and are catchable:
`:nextomic/unknown-attribute`, `:nextomic/value-type`,
`:nextomic/unique`, `:nextomic/conflict`, `:nextomic/no-entity`,
`:nextomic/unbound-pattern`, `:nextomic/basis-in-future`,
`:nextomic/closed`, `:nextomic/busy` (`release` while an operation on
the connection is in flight), `:nextomic/tx-data` for malformed
tx-data, a lookup ref on a non-unique attribute, a nested map nothing
could reach, or a unique card-many attribute, `:nextomic/history-view`
(`entity` or `pull` on a history db) and `:nextomic/nested`
(`transact!` or `with` while a `with` holds the write transaction).

An error that can say more travels as a map, `{:error keyword ...}`,
whose other keys name what went wrong; one that cannot is the bare
keyword. The shapes:

| error | payload |
|---|---|
| `:nextomic/unknown-attribute` | `:attr`, the keyword or id the program used |
| `:nextomic/value-type` | bare |
| `:nextomic/unique` | `:attr` and `:value` |
| `:nextomic/conflict` | `:e` and `:a`, the datom the two claims disagree on |
| `:nextomic/no-entity` | bare |
| `:nextomic/tx-data` | `:message`; `:attr` when an attribute is at fault |
| `:nextomic/query-syntax` | `:message`; `:clause`, the index into `:where`, when the parser or planner was inside a clause (an unbound function name is reported the same way at run time) |
| `:nextomic/pull-syntax` | `:message`; `:clause`, the index of the spec in the pattern (from `pull`, `pull-many` or a `(pull ?e pattern)` find element) |

The map is what `catch` receives; `(:error m)` is the keyword. A key is
present only when its value is known. Engine errors surface as the
`db.zig` keyword set (`:db/key-too-large`, `:db/map-full`,
`:db/corrupted`, ...). A released connection keeps its struct so a
db-value taken from it raises `:nextomic/closed` rather than dangling.

---

## 8. Module layout

```
src/nextomic/
  root.zig       module root; re-exports
  key.zig        sortable encodings, index key pack/unpack, prefix successor
  datom.zig      Datom, txlog entry codec
  store.zig      Env ownership, 11 TreeIds, bootstrap, sys counters, raw put/del/scan
  idents.zig     durable keyword <-> id, per-connection cache
  schema.zig     Schema from attribute datoms as-of a basis, per-attribute counts
  transact.zig   §3
  db.zig         DbValue, fold, datoms, entity, entid/ident, tx-range
  handle.zig     heap bodies of the two value kinds; its own module
                 `nextomic_handle` below dispatch/format/gc, so their
                 kind arms need nothing from the module above them
  marshal.zig    VM values to and from datom values: the entity, value and cell contracts
  relation.zig   columnar Relation
  query/ir.zig  query/parse.zig  query/plan.zig  query/exec.zig  query/rules.zig
  pull.zig
  natives.zig    nextomic/* NativeFn table, error mapping, installNextomic
  query/natives.zig  q and explain
stdlib/nextomic.nx   sugar only (with-conn)
test/prop/nextomic_key.zig     order(enc a, enc b) == cmp(a, b) per type
test/prop/nextomic_tx.zig      random transactions vs an in-memory model, every basis
test/integration/nextomic_fx.zig    the fixture the corpora share
test/integration/nextomic_q.zig     query corpus vs a naive evaluator
test/integration/nextomic_pull.zig  pull corpus vs a naive evaluator
test/nextomic/*.nx             end-to-end scripts
```

`nextomic` is one build module above `dispatch` and `vm`, imported by
`stdlib` only; `cli` installs it through `stdlib.installNextomic` and
bootstraps `stdlib/nextomic.nx` with the `nextomic` namespace current.
Value kinds: `nextomic_conn`, `nextomic_db` (heap boxes from
`handle.zig`; the connection box holds the `Conn` the VM owns on
`vm.nextomic_connections` plus its path text, the db box that pointer
and the basis/mode numbers; both are collector leaves). Nextomic never uses the
`db/*` layer's per-operation tree opens or codec-encoded keys; it holds
raw `*emdb.Txn` handles and byte keys, and uses `db.Connection` only for
the `Env`.

---

## 9. Runtime prerequisites

- **Page size pinned** and the `db.zig` double free fixed (blocking; the
  seam work).
- **VM stack invariant on nested calls** (blocking for user-function
  predicates and transaction functions; built-in predicates need
  nothing).
- **GC**: not blocking. Every Nextomic operation allocates in its own
  arena and copies only results into the VM heap. Wiring the collector
  bounds process lifetime, not correctness.
- **Number tower**: blocking only for double predicates and aggregates.
  Doubles are storable from the start.

---

## 10. Where Nextomic wins, and where it does not

Wins, by construction: sub-10 ms open; reads straight off the mapping
with no deserialization; empty-value index leaves; history as a range
filter; one file, one process, backup by transaction number. Measured
claims wait for the benchmark suite; nothing in this document asserts a
multiplier.

Not in scope: distribution (Datomic's peer/transactor split), a
cost-based optimizer beyond greedy selectivity, write-heavy OLTP beyond
one writer.

---

## 11. emdb: nothing required

Two wishes noted and worked around, so that the engine stays untouched:

1. A transaction id accessor: the public `Txn.txnId` field is not used;
   Nextomic's own `t` is read from `sys` inside the same snapshot.
2. Full multi-page overflow values off a cursor (cursors clamp to one
   page): index trees carry only `[t]` in current trees and nothing in
   history trees; out-of-line payloads and txlog entries are read with
   `Txn.getFromTree` on the exact key, which assembles every page.
