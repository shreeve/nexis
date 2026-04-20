# NEXTOMIC.md — Architecture for a Datomic-class database on nexis + emdb

> **Status: post-v1 design reference. Authoritative for Nextomic architecture
> decisions when the library is scoped, but does NOT modify any v1 PLAN.md §23
> frozen decision. Nextomic is explicitly not a v1 deliverable (PLAN.md §15.11).**

---

## 0. What this document is

This is the comprehensive architecture reference for **Nextomic** — the
codename for a Datomic-class embedded database that will be built as a
nexis library on top of `emdb`, after nexis v1 ships.

`PLAN.md` §15.11 is the *opportunity statement*. This document is the
*architecture* — deeper on all of:

- Why emdb + nexis is the right substrate (not a rhetorical claim).
- The specific frozen-once-scoped architectural decisions that separate
  "credible 2026-class Datomic successor" from "beautiful
  proof-of-concept."
- Exact storage layout: named sub-databases, key encodings, value
  encoding discipline.
- The semantic model: datoms, entity ids, schema, tx-log.
- The query compilation pipeline: macro → IR → plan → executor.
- What `emdb` does NOT need (zero changes) and why that matters.
- What wins this buys and what it doesn't.

### Authority

1. `PLAN.md` §23 frozen decisions — still highest authority for v1.
2. `PLAN.md` §15 durable-identity contract — load-bearing for
   Nextomic; must not regress.
3. **This document** — authoritative for Nextomic library architecture.
   When Nextomic is scoped, frozen decisions in §3 below become
   binding in the same way §23 decisions are binding for v1.
4. All other docs — derivative.

### How this document was produced

Through two rounds of adversarial architectural review with a peer AI
(GPT-5.4 via `user-ai` MCP). Round one established that emdb alone is a
good *index* substrate but not a semantic substrate without a canonical
append-only datom log. Round two, after the peer was shown the nexis
codebase in depth, established the eight-point architectural split
captured in §3 of this document. The review flagged what could make
Nextomic great versus merely functional. This doc captures that bar.

---

## 1. The core thesis

> **emdb + nexis is the right foundation for Nextomic — genuinely, not
> rhetorically — IF you commit to:**
>
> 1. Integer entity ids, not durable-refs.
> 2. A specialized internal Relation type (typed-vector columns),
>    separate from the API persistent-set-of-persistent-vectors.
> 3. A macro → IR → runtime-plan split (not "everything is a macro"
>    and not "everything is a runtime plan").
> 4. tx-in-key filtering for historical semantics, not emdb snapshot
>    pinning.
>
> Do those four things and you have something neither Clojure nor
> Datascript can match on embedded single-node workloads. Skip them
> and you have a lovely Zig-native Datascript. That is the entire
> delta between "serious contender" and "charming toy."

The substrate is unusually well-matched. Several structural alignments
that most "build a Datomic on X" projects lack from day one:

| Alignment | Where | Why it matters |
|---|---|---|
| Snapshot isolation with lock-free readers | emdb `INV-T02`, `INV-T13` | A Datalog query opens a read tx at start and every clause sees the same basis — no phantom reads across joins |
| Multiple independent B+ trees per file | emdb `INV-SUB01..06` | EAVT/AEVT/AVET/VAET/log/schema are separate named trees, atomically published by one meta-page flip |
| Atomic multi-tree commit | emdb `INV-T07A`, `INV-M03` | Transact writes all index updates, the log append, and any schema change as a single atomic value |
| Prefix-compressed branch pages | emdb `SPEC.md §5.0.2` | Composite EAVT keys share 8-16+ byte prefixes across adjacent keys; branch-page G=1/G>1/G<0 compression was tuned for exactly this shape |
| Zero-copy mmap reads | emdb `INV-WM01` | String/bytes values can point into mmap pages for the read tx's duration — no deserialization cost |
| Persistent collections with structural equality | nexis `PLAN.md §9`, §23 #36 | `(= (list 1 2 3) (vector 1 2 3))` — query result literals interoperate trivially |
| Durable-ref as first-class value kind | nexis `PLAN.md §15.2`, §23 #7 | Identity bridge between runtime and storage already exists — reuse at the `(db/ref ...)` layer |
| Explicit lexical transactions, no STM | nexis §15.3, §23 #6 | `(with-tx ...)` shape cleanly mirrors Datomic's transact boundary |
| `as-of` as first-class in v1 | nexis §15.7, §23 #22 | Snapshot-as-value infrastructure is already committed; Nextomic reuses it |
| Three-representation discipline | nexis §5, §23 #17 | Form ≠ Value ≠ Encoded — exactly the separation Datalog needs between query syntax, query plan, and datom storage |
| Arena allocators for compile intermediates | nexis §10 | Query compilation produces many transient Forms and IR nodes; arena-freed at end of expansion |

None of these is a Nextomic-specific concession. They all already exist
(or are frozen commitments) for independent v1 reasons.

---

## 2. Prior art

| System | Language | What we take | What we reject |
|---|---|---|---|
| **Datomic** (Hickey, 2012) | Clojure/JVM | Datom model `[e a v tx op]`, four covering indexes, database-as-value, Datalog+pull syntax, time as first-class, schema-as-datoms | Cloud-storage abstraction over DynamoDB/Cassandra (wrong shape for embedded); peer/transactor separation (single-process simpler for local-first) |
| **Datahike** (replikativ, 2018+) | Clojure/JVM | Proof that Datomic semantics work on LMDB-class engines in open-source; API shape for embedded use | JVM heap cost per datom; deserialization-heavy read path |
| **Datascript** (tonsky, 2015+) | ClojureScript | Datalog compiler techniques; in-memory representation ideas for query engine | In-memory-only constraint; host-language representation costs |
| **XTDB** (JUXT, 2019+) | Clojure/JVM | Bitemporal potential; document-style datoms as an alternative to flat datoms | Log-native segment architecture (wrong shape for local-first B+ tree substrate) |
| **Datalevin** (juji-io, 2020+) | Clojure/JVM | Pattern of "embedded Datalog over LMDB" — closest spiritual cousin to Nextomic | JVM layer still sits between query engine and LMDB |

Nextomic's unique position: **pure-Zig, vertically integrated, mmap-native,
single-process embedded, with the host language and database co-designed
from the start.** No JVM, no deserialization, no host/engine impedance
mismatch. This is a lane no existing Datomic-successor occupies.

---

## 3. Architecture — frozen once scoped

When Nextomic is scoped as an active project, the following six
decisions become binding. Changing one requires an amendment to this
document with stated rationale, in the same discipline as PLAN.md §23.

### 3.1 Integer entity ids (not durable-refs)

**Decision.** Entity ids (`eid`) are plain fixnums (i48 fits 140
trillion entities — more than any realistic database). Attribute ids
(`aid`) are `u32` keyword intern ids. Durable-refs remain the low-level
handle type for the `nexis.db` API, but are **not** the Nextomic entity
identity.

**Why.** `durable-ref` is `{store-id: u128, tree-id: Keyword,
key-bytes: []u8}` — heavy (~40+ bytes), and it encodes storage topology
into identity. Letting entity ids be durable-refs would:

- Bloat every EAVT/AEVT/AVET/VAET index key.
- Force 40-byte compares and hashes during joins instead of 8-byte
  integer compares.
- Tie semantic identity to storage location, forbidding re-homing data.
- Complicate tempid resolution, import/export, and cross-store
  references.

Fixnum eids:

- Fit the 16-byte `Value` payload word with no heap allocation.
- Compare/hash in a single machine instruction.
- Match Datomic's eid semantics directly.
- Interoperate with Nexis's existing tagged-value fast paths.

**Three-layer identity model.** Nextomic exposes three identity
concepts, cleanly separated:

| Identity | Representation | Purpose |
|---|---|---|
| Entity id (`eid`) | `fixnum` | Semantic database identity; appears in every datom and index key |
| Attribute id (`aid`) | `u32` keyword intern id | Compact attr in hot paths; keyword is the user-facing surface |
| Lookup ref | `[:user/email "alice@x"]` vector literal | User-facing identity via unique attr; resolved by AVET scan at query time |
| Durable-ref (pre-existing) | PLAN.md §15.2 triple | Lower-level `nexis.db` API only; NOT Nextomic's entity model |

### 3.2 Internal Relation type (not persistent-set-of-persistent-vectors)

**Decision.** Nextomic owns a runtime-private `Relation` struct — a
column-oriented container backed by existing `typed_vector` Value
kinds. This is the execution representation. Query results are
materialized to `persistent-set` of `persistent-vector` (or
`vector-of-map` via pull) **only at the API boundary**.

**Why.** PLAN.md §15.11 currently says "persistent-set of
persistent-vector — no impedance mismatch." That is true at the API
boundary and false at every internal pipeline stage. A
persistent-set-of-persistent-vector is:

- Great for a 10-row answer a human sees.
- Barely acceptable for a 10k-row materialized result.
- Cache-hostile and allocation-heavy for a 1M-row intermediate relation
  during a multi-way join.

Datascript demonstrates that generic-persistent-collections-all-the-way
is **correct** and **slow**. Datomic's internals do not look like
Datascript's internals for exactly this reason.

**Relation shape.**

```
Relation {
  arity:          u16                    // number of columns
  row_count:      u64
  var_to_col:     [Symbol → u16]         // map logical variables to column indices
  columns:        [Column × arity]
  sorted_by:      ?u16                   // optional: column index this is sorted by
  unique_col:     ?u16                   // optional: column with uniqueness property
}

Column = union {
  EidCol:       typed_vector<u64>        // entity ids
  AidCol:       typed_vector<u32>        // attribute ids
  TxCol:        typed_vector<u64>        // transaction ids
  FixnumCol:    typed_vector<i64>        // integer values
  FloatCol:     typed_vector<f64>        // floating-point values
  BoolMask:     bitmap                   // booleans / op column
  TaggedCol:    [Value]                  // heterogeneous scalar values
  StringRefCol: [Value]                  // strings (Value payload points into mmap or heap)
}
```

The three-representation boundary (PLAN.md §5) is preserved: `Relation`
lives in Layer 2 (Runtime Value), never hits the codec in Layer 3.
It is a runtime-private container, structurally analogous to
`DirtyPageMap` inside emdb — a performance tool, not a user value.

**Why this lane is winnable.** Nexis already has typed-vector as a
frozen value kind with SIMD kernels in `nexis.simd`. Using it for
relation columns is the single highest-leverage design decision
Nextomic will make. It is the difference between "~2× slower than
Datascript's JS" and "~5× faster than Datahike's JVM."

### 3.3 Macro → IR → runtime-plan split

**Decision.** Query compilation is split across three stages:

| Stage | Done by | Artifact |
|---|---|---|
| **Parse-time (macro)** | `nexis.nextomic/q` as a macro | Query IR (a small, canonical data structure) — embedded as a literal constant in the caller's bytecode |
| **Plan-time (runtime)** | `nexis.nextomic.planner/plan` called by the expanded macro body | Executable plan specialized to current schema + input bindings |
| **Execute-time (runtime)** | `nexis.nextomic.exec/run` | Relation → materialized API result |

**Why not entirely in macros.** Macros only see syntax at expansion
time. Datalog planning is partly static, partly dynamic:

- Schema (indexed / unique / ref / cardinality per attr) is a runtime
  value.
- Which `?vars` are bound at call time affects plan choice.
- Selectivity hints evolve with the data.
- Rules can be assembled dynamically; queries can be passed as values.

**Why not entirely at runtime.** Parse-time work lets Nextomic do
things no existing Datalog implementation does cleanly:

- Clause-shape validation with source spans (`Form.origin`, PLAN.md §5).
- Rewrite lookup refs into explicit AVET probes.
- Detect constant-only clauses and lift them.
- Emit IR as a literal constant — zero parsing cost per query
  invocation, even on cold cache.
- Compiler-visible variable slots for the execution engine.

**Why macros are genuinely leverage.** `(d/q '[:find ?e ...] db)` IS a
nexis Form. Nexis macros receive `&form` and `&env` (PLAN.md §23 #34).
Clojure-on-JVM Datalog libraries cannot do this cleanly because their
reader/compiler boundary is different. In nexis this is native.

**Concrete macro sketch.**

```clojure
(defmacro q [query db & inputs]
  (let [qir (nextomic.compile/compile-query &form query)]
    ;; `qir` becomes a literal constant embedded in the caller's bytecode.
    `(nextomic.run ~qir ~db ~@inputs)))
```

### 3.4 tx-in-key for history (not snapshot pinning)

**Decision.** Historical query semantics (`as-of`, `since`, `history`)
are answered by range filtering on the `tx` component of composite
index keys. Datoms are stored append-only; retraction is a new datom
with `op = false`. emdb's native snapshot pinning is operational — used
only when the user explicitly asks for a long-lived reproducible
reference (debug sessions, external consistency across many API calls).

**Why.** Datomic semantics require history as data, not as page
retention. A `as-of T` database value is defined by "the datoms
asserted by transactions ≤ T." That is a pure range filter in tx-in-key
indexes — no storage-layer snapshot needed.

**Two consequences:**

- **Consistency of one query** still requires a read tx held for the
  query's duration (so cursors on different indexes see the same emdb
  snapshot). This is the operational snapshot — short-lived, always
  released.
- **Historical correctness** comes from the datom history itself, which
  never disappears. emdb's free-list reclamation continues to operate
  on pages because the *current* indexes' pages that were superseded
  can be freed — the datoms those pages held are still referenced by
  the tx-in-key history rows in the current indexes.

**Why this is a better answer than snapshot pinning.** Long-lived
pinned snapshots in emdb prevent page reclamation and grow the file
without bound. PLAN.md §15.7 flags this honestly. Routing history
through tx-in-key eliminates the cost almost entirely — pinning is
reserved for the narrow case where the user genuinely needs it.

### 3.5 Datom as a heap kind (user-facing projection only)

**Decision.** Add `datom` as a new heap `Kind` in `src/value.zig`.
Reserves one slot in the 30..63 range Nexis already has open for heap
kinds. A datom value has five accessors: `.e`, `.a`, `.v`, `.tx`, `.added?`.

**Why a heap kind, not a vector of five Values.** For user-facing
projection only — cheaper accessors, nicer print representation,
identity equality semantics, avoidance of allocating a tiny
persistent-vector per emitted datom. The execution engine does NOT use
this type; it works on `Relation` columns (§3.2).

**Serialization.** The datom heap kind serializes by projecting its
five fields through the existing §15.10 codec matrix — all five of
`eid: fixnum`, `aid: keyword`, `v: various`, `tx: fixnum`, `op: bool`
are already serializable. **The §15.10 codec matrix does NOT need to
be extended.** No PLAN.md amendment required.

### 3.6 Storage layout — one named sub-DB per concern

**Decision.** Nextomic uses emdb named sub-databases (`maxNamedTrees`)
for all storage. Default `maxNamedTrees = 128` in emdb's `EnvOptions`
is >10× what Nextomic needs.

| Named tree | Key | Value | Purpose |
|---|---|---|---|
| `:nextomic/txlog` | `tx:be-u64` | encoded `[datom+]` | Canonical append-only source of truth |
| `:nextomic/eavt` | `[e:be-u64][a:be-u32][v:sortable][tx:be-u64][op:u8]` | empty | Entity-centric scans |
| `:nextomic/aevt` | `[a:be-u32][e:be-u64][v:sortable][tx:be-u64][op:u8]` | empty | Attribute-scan |
| `:nextomic/avet` | `[a:be-u32][v:sortable][e:be-u64][tx:be-u64][op:u8]` | empty | Value lookup (indexed / unique attrs only) |
| `:nextomic/vaet` | `[v-ref:be-u64][a:be-u32][e:be-u64][tx:be-u64][op:u8]` | empty | Reverse refs (ref-valued attrs only) |
| `:nextomic/schema` | `a:be-u32` | encoded schema map | Per-attr `:db/valueType`, cardinality, uniqueness, ref? |
| `:nextomic/idents` | `keyword-text` | `aid:be-u32` | Keyword → attr-id resolution |
| `:nextomic/sys` | `"eid-seq"` | `last-eid:be-u64` | Monotonic entity id allocator |

Keys are binary-sortable byte strings — emdb's default SIMD unsigned-lex
comparator is exactly the ordering Nextomic requires. The
`v:sortable` encoding includes a 1-byte type tag so numeric values sort
numerically and strings sort lexicographically within their type.

**Index values are empty.** In EAVT/AEVT/AVET/VAET, the key *is* the
datom — no separate value is needed. This maximizes B+ tree leaf
density and leverages emdb's prefix compression fully.

**Write path.** A single `transact!` opens one emdb write tx, updates
all relevant indexes + the txlog + any schema changes, and commits
once. emdb's `INV-T07A` (Phase 2 data sync before Phase 3 meta write)
gives atomic cross-index publication for free.

---

## 4. Three-representation boundary — what stays where

PLAN.md §5 is unchanged and unchallenged. Nextomic fits cleanly:

| Layer | Contains (Nextomic) |
|---|---|
| **Form** (Layer 1) | Query literal `'[:find ?e :where ...]`, rule definitions, `transact!` data vectors, schema declarations. Macros see Forms. Source spans drive diagnostics. |
| **Runtime Value** (Layer 2) | db-value (`{conn, basis-tx}`), snapshot (`{conn, tx-id}`), Query IR, runtime plan, `Relation`, variable bindings, result tuples, datom projections. Nothing here hits the codec. |
| **Durable Encoded** (Layer 3) | Datom bytes in `eavt`/`aevt`/`avet`/`vaet`, tx-log entries in `txlog`, schema entries in `schema`. Only via the §15.10 codec. |

**Rules and queries as data** round-trip through the codec because
they are just nested collections of keywords, symbols, numbers, strings,
and vectors — every kind in the §15.10 serializable matrix. A user can
persist a named query, load it later, and run it. **Compiled query
plans do NOT round-trip and shouldn't.** That would fuse layers 2 and
3, which §5 forbids.

---

## 5. Query compilation pipeline

End-to-end flow for `(d/q '[:find ?name :where [?e :user/name ?name]] db)`:

```
1. READ
   nexis.grammar parses source → Sexp → Form
   The quoted query literal is a Form datum — a vector containing
   keywords, symbols, other vectors. Carries source spans.

2. MACRO EXPANSION (parse-time, once per call site)
   nexis.nextomic/q receives (&form, &env, query-form, db-expr, *inputs)
   Calls nexis.nextomic.compile/compile-query on the query Form:
   - Validates clause shape (errors with source span if malformed)
   - Normalizes clauses (rewrites lookup refs, constants, predicates)
   - Allocates variable slots
   - Emits Query IR: a canonical small struct
   Expands to:
     (nexis.nextomic/run <IR-literal> db inputs...)
   IR is embedded as a bytecode literal-pool entry — no re-parsing cost.

3. PLAN (runtime, may be cached per (IR-hash, schema-basis, input-shape))
   nexis.nextomic.planner/plan takes the IR + current db schema + bound
   inputs:
   - Orders clauses by estimated selectivity
   - Chooses which index drives each clause (EAVT/AEVT/AVET/VAET)
   - Plans join order and join types
   - Emits executable plan

4. EXECUTE (runtime)
   nexis.nextomic.exec/run iterates the plan:
   - Opens one emdb read tx for query duration
   - Drives emdb cursors on chosen indexes
   - Builds/merges Relations column-wise
   - Evaluates predicates on typed columns where possible
   - Final projection to the :find shape

5. MATERIALIZE (runtime)
   Convert execution Relation → API shape
   (persistent-set of persistent-vector by default)

6. RETURN to user
```

**Cold-query cost.** ~0 macro cost at call time (IR is a literal),
planner runs once, executor traverses mmap'd pages. A query whose
scan plan hits warm pages can complete in a few μs. This is the regime
where Nextomic can outperform Datomic-on-JVM by orders of magnitude on
cold startup specifically — no class loading, no JIT warmup, no JDBC
round-trip.

---

## 6. Schema

Schema is the second-biggest Nextomic risk after query engine
representation. PLAN.md §15.11 does not address schema; this section
does.

### 6.1 Schema as datoms

Following Datomic: the schema for attribute `:user/name` is itself a
set of datoms on an entity representing that attribute, with
meta-attributes like `:db/valueType`, `:db/cardinality`, `:db/unique`,
`:db/index`, `:db/isComponent`.

### 6.2 Attributes the planner needs at runtime

| Attr meta | Values | Why the planner needs it |
|---|---|---|
| `:db/valueType` | `:db.type/string`, `:db.type/long`, `:db.type/ref`, `:db.type/keyword`, `:db.type/boolean`, `:db.type/float`, `:db.type/instant`, `:db.type/uuid`, `:db.type/bytes` | Determines the binary-sortable encoding used for `v` in keys |
| `:db/cardinality` | `:db.cardinality/one` or `:db.cardinality/many` | Retraction and uniqueness semantics |
| `:db/unique` | `nil`, `:db.unique/identity`, `:db.unique/value` | Drives lookup-ref resolution; enforces uniqueness on assertion |
| `:db/index` | `true` or `false` | Controls whether AVET is populated for this attr |
| `:db/isComponent` | `true` or `false` | Influences retraction cascade and pull traversal |
| `:db/doc` | string | Diagnostics; not performance-critical |

### 6.3 Bootstrap

The schema-for-schema is bootstrapped on database creation — the small
set of attributes describing attributes themselves is written as datoms
in the first transaction. All subsequent schema modifications are just
transactions that assert more schema datoms.

### 6.4 The planner reads schema at plan-time, not at every query

The `Schema` value is cached in the db-value at the time it is
captured. A query planning against that db-value sees schema as of
that basis-tx. Plan cache keys include a schema-hash so re-planning
occurs on schema change.

---

## 7. What emdb does NOT need to change

**Nothing. Zero changes.** The full rationale is in `../emdb/NEXTOMIC.md`.

One affordance *already exists* and is all that Nextomic will ever ask:

- Stamp a db-value's `basis-tx` from `Env.info().lastTxnId`
  (`../emdb/src/emdb.zig`). Already exposed, no code change.

Four temptations to refuse if they arise during Nextomic
implementation — each has a correct Nexis-side answer:

| Temptation | Nexis-side answer |
|---|---|
| Add a typed key comparator to emdb | Encode types into key bytes so default lex-sort matches value-sort |
| Add "read at arbitrary historical txn_id" to emdb | Route history through tx-in-key filtering (§3.4) |
| Add record/tuple awareness to emdb | Encode datoms into byte keys; emdb sees only bytes |
| Add Nextomic-specific APIs to emdb | Compose existing emdb primitives (named trees, cursors, range scans, read txns) on the Nexis side |

The default answer to each is no — and the architectural discipline
that produced this document is the reason why.

---

## 8. What em does NOT need to change

**Nothing. Zero changes.** em is prior art, not a runtime dependency.
Nexis reuses em's ideas (64-bit bytecode ISA shape, tail-call
dispatcher pattern, slot/register VM, routine cache format) by
re-implementing them in its own codebase. em does not appear as a
`build.zig.zon` dependency of nexis.

---

## 9. Where Nextomic can actually win

Not every workload. But in specific lanes, the stack has structural
advantages that neither Datomic nor Datahike can replicate:

| Workload | Why Nextomic wins | Expected advantage (aspirational) |
|---|---|---|
| Cold-start embedded query | mmap'd `.nx.o` + emdb open in <10ms vs JVM class-loading + Datahike init in hundreds of ms | 10–50× on end-to-end first-result latency |
| Zero-copy large-string read | emdb overflow pages + Nexis `string` Value payload points into mmap | 10–50× on large-blob reads |
| Historical range scan (tx-in-key) | SIMD-accelerated cursor + G>1/G<0 prefix compression on composite EAVT keys | 3–10× on history traversal |
| Numeric analytical aggregation over a Relation | `typed-vector` columns + `nexis.simd` kernels; approaches ~40 GFLOPS per core on f64 | Orders of magnitude over Datahike/Datascript. **No managed-runtime Datomic-successor can compete in this lane.** |
| REPL-driven query development | Macroexpand the query and see exactly what IR it produces; sub-millisecond round-trip | Qualitative: interactive experience Clojure cannot match on JVM |

**Natural lane.** Embedded / single-node / local-first / read-mostly.
Enormous 2026 demand (local-first apps, on-device AI agents with
memory, developer tooling, CLI-embedded knowledge graphs) with no
dominant player.

Where Nextomic will NOT win v1, and should not try:

- Distributed deployment. Datomic peer/transactor split exists for
  reasons Nextomic does not yet address.
- Advanced query optimization. Datomic's decade of planner work is
  real. Nextomic ships a simple-but-correct planner first; any
  competitive optimizer is v2+.
- Write-heavy transactional OLTP. emdb is single-writer; that is a
  feature for consistency, a limit for write-scale.

---

## 10. Implementation estimate

PLAN.md §15.11 estimates ~4–5k LOC. This document's finer-grained
breakdown, reflecting the architecture above:

| Module | LOC estimate | Notes |
|---|---|---|
| Datom encoding + five named trees + tx-log | 1,500 | Direct emdb usage; binary-sortable key encoders |
| Schema + unique/indexed/ref attr handling | 800 | Revised up from PLAN.md's 500 — schema is underscoped there |
| Internal `Relation` type + column kernels | 600 | New; builds on existing `typed_vector` |
| Query compiler (macro → IR) | 500 | Parse-time validation, normalization, slot allocation |
| Runtime planner (IR → plan) | 800 | Selectivity heuristics; index choice; join ordering |
| Executor + cursor drivers | 900 | Opens read tx, drives emdb cursors, builds Relations |
| Pull syntax | 500 | Entity graph expansion |
| Temporal ops (`as-of`, `since`, `history`) | 300 | Mostly riding on §15.7; composition |
| Datom heap kind + 5 accessors | 200 | `src/value.zig` addition, one new slot in Kind enum |
| **Total** | **~6,100** | Up from 4–5k once schema and Relation costs are honest |

All of this is nexis-side code. Zero lines in `../emdb/` or `../em/`.

---

## 11. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| N1 | Generic execution representation (falling back to persistent-set-of-persistent-vector internally) | **High** | **Severe** — this is the difference between "great" and "works" | Commit to `Relation` type §3.2 before first planner code lands |
| N2 | Schema machinery underdesigned | High | Severe | §6 of this doc; amend before first `transact!` lands |
| N3 | Query planner stays "simple nested-loop forever" | Medium | Moderate | Ship a minimal planner first; invest in selectivity heuristics once real workloads exist |
| N4 | Someone tries to extend emdb with Nextomic-specific APIs | Medium | Severe | `../emdb/NEXTOMIC.md` §4 names the four temptations to refuse |
| N5 | Someone tries to extend the §15.10 codec matrix to handle query plans | Low | Moderate | §5 three-representation discipline; codec amendment requires PLAN.md change |
| N6 | `as-of` leaning on emdb snapshot pinning instead of tx-in-key | Medium | Moderate | §3.4 is explicit; pinning is operational only |
| N7 | Write amplification under long-running append-only history in B+ tree pages | Low | Moderate | Honest documentation; history-compaction strategy is a v2 concern |
| N8 | "Nextomic" name survives to ship | Low | Low | PLAN.md §15.11 already notes the shipped library will have a cleaner name |

---

## 12. Pre-scope checklist

Before writing any Nextomic code, this needs to be in place:

- [ ] `PLAN.md` §15.11 amended to reference this document and to
      record the §3 frozen-once-scoped decisions inline.
- [ ] `src/value.zig` `Kind` enum has a reserved slot and comment
      for `datom` (does not require implementation at reservation
      time).
- [ ] `build.zig.zon` pins a specific `emdb` version (PLAN.md §25
      risk #7 — Nextomic makes this risk real).
- [ ] `docs/CODEC.md` audited: confirm no Nextomic-specific entries
      are needed. Datoms serialize via projection to existing kinds.
- [ ] Throwaway branch: 500 LOC nested-loop-join Nextomic prototype
      to smoke-test the macro → emdb-cursor path end-to-end before
      committing to the full architecture.

---

## 13. Bottom line

> **Nexis + emdb is the right foundation for Nextomic — genuinely, not
> rhetorically — and it can ship as a serious 2026+-class embedded
> Datomic successor if and only if the four commitments in §1 are
> followed without compromise.**

The seven years of emdb-style B+ tree discipline and the em-shaped VM
ISA are already load-bearing exactly where Nextomic needs them. The
only risk is wasting that substrate by letting the query engine stay
"Lisp-pure" instead of making it brutally specialized where it counts.

---

*Document version: 1.0 — Produced 2026-04-19 after two-round peer-AI
architectural review. Companion to `PLAN.md` §15.11. For the
corresponding emdb-side notes, see `../emdb/NEXTOMIC.md`.*
