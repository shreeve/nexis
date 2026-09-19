# HANDOFF.md — nexis and Nextomic for a new session

Self-contained. Everything a new session needs is in this repository
and its sibling `../emdb`; no conversation, tool or transcript is a
prerequisite. `AGENTS.md` is the short routing guide; this file is the
long one. Every number here comes from the tree this file
describes; when the tree moves, the counts in §2 move with it.

---

## 1. What this is

**nexis** is a Lisp with Clojure semantics implemented in Zig 0.16 on
its own runtime: a grammar-generated reader, a macroexpander, a
compiler to a 64-bit bytecode, a slot VM, persistent collections
(CHAMP map and set, 32-way vector, cons list, transients), a 16-byte
tagged value, and the emdb storage engine underneath. `bin/nexis run
FILE.nx` and `bin/nexis repl` run real programs: `defn`, `defmacro`,
namespaces with `require`, destructuring, multi-arity `defn`, atoms,
records and protocols, keywords and collections as functions, doubles
with Clojure contagion, `try`/`catch`/`finally` with every error a
catchable value. It is not a Clojure port: there is no Java interop,
no STM, no JVM ecosystem, one isolate and one thread. The trade is a
static binary that starts instantly and carries durable storage and a
database in the same process.

**emdb** is the storage engine: a memory-mapped, copy-on-write, MVCC
B+ tree with named trees, one writer, wait-free readers, byte keys in
unsigned lexicographic order. nexis uses it two ways. The `db`
namespace exposes durable refs: named-tree key-value storage with
explicit `with-tx`/`with-read-tx` transactions, `@deref`, `db/alter!`,
`db/scan`, `db/reduce-tree` and MVCC snapshots. Nextomic uses the
engine directly, below that layer, and shares only the `Env` and the
`:db/*` error names with it. emdb is unchanged for either; that is a
standing rule (§4).

**Nextomic** is a Datomic-class database inside the binary. Datomic's
idea is that a database is a value: it stores facts, not rows, never
overwrites them, and stamps every fact with the transaction that
added it, so "what did we know at transaction 900?" and "what changed
since?" are ordinary reads rather than archaeology. A fact is a datom
`[e a v t added]`; the store keeps every datom it ever learned; a
db-value is an immutable view at a basis `t`; `as-of`, `since` and
`history` are views of the same trees; queries are Datalog data;
transactions are data too. Nextomic maps that onto emdb with byte
keys whose order is the index order: four current trees answer
ordinary reads with no per-fact fold, four history trees carry the
transaction in the key and answer the time views, and `nx/txlog`,
`nx/idents` and `nx/sys` complete eleven named trees in one file. One
process, one file, no transactor, and any number of processes can
open the file and see each other's writes.

---

## 2. Verify on arrival

`../emdb` must be a sibling checkout and `zig` must be 0.16.0
(`ZIG-0.16.0.md`). Everything below runs from the repository root.

```bash
git status                        # clean main
zig build install                 # bin/nexis and bin/nexis-golden
./bin/nexis --help                # usage; lists the namespaces available without a file
zig build quick                   # the inner loop, ~35-50 s warm
zig build test --summary all      # the gate: 1338 tests, 140 steps, ~4 min wall
```

The gate's last line reads `Build Summary: 140/140 steps succeeded;
1338/1338 tests passed`, preceded by `golden: ok=10 updated=0
failed=0 missing=0`. Two integration binaries end with a benchmark
whose row-count checks always run; the build runner echoes their
stderr as `failed command:` lines while both succeed, so read the
summary line, not the noise.

The build steps, and what each is for:

| step | runs | time (warm, Debug) |
|---|---|---|
| `zig build quick` | the language binaries (`vm`, `compile`, `expand`, `stdlib`, `loader`, `atom`, `record`, `protocol`, `format`), the compile property tests, `test/integration/{eval_pipeline,runtime_polish,numbers}.zig`, the Nextomic unit binary and its two property tests | ~35-50 s |
| `zig build nextomic-test` | `src/nextomic/*` unit tests, `test/prop/nextomic_{key,tx}.zig`, `test/integration/nextomic_{q,pull}.zig` | ~33 s |
| `zig build nextomic-nx` | every `test/nextomic/*.nx` through `bin/nexis`, stdout diffed against its `.out` | seconds |
| `zig build examples` | every `examples/*.nx` through `bin/nexis`; `durable-refs`, `todo-app` and `nextomic-app` twice | seconds |
| `zig build golden` | reader goldens (`-Dupdate=true` rewrites them) | seconds |
| `zig build test --summary all` | all of the above plus every module's inline tests and the randomized collection gates | ~4 min |
| `zig build bench` | the ReleaseFast benchmark harness (`docs/BENCH.md`) | minutes |
| `zig build parser` | regenerates `src/parser.zig` from `nexis.grammar` via `../nexus/bin/nexus` | seconds |

The one environment variable is `NEXTOMIC_BENCH`: when set, the two
Nextomic corpora print `[bench]` timing lines to stderr
(`NEXTOMIC_BENCH=1 zig build nextomic-test --summary all`). Debug
numbers under the testing allocator are not performance
measurements; `docs/PERF.md` §3.7 has the ReleaseFast ones and the
command that reproduces them.

The examples are the fastest end-to-end check:

```bash
./bin/nexis run examples/nextomic-app.nx   # clinic chart; run it twice, the second run upserts
./bin/nexis run examples/todo-app.nx       # durable refs across processes; second run shows :completed 1
./bin/nexis run examples/shapes-app.nx     # multi-file protocols + records + atoms; total-area atom = 9650
./bin/nexis repl                           # :quit or EOF exits
```

`test/nextomic/query.nx` is the fastest tour of the Nextomic surface;
the `.nx` scripts are the executable specification.

---

## 3. Architecture map

### 3.1 The pipeline

```
source.nx
   │  src/parser.zig      generated by nexus from nexis.grammar (committed)
   ▼
raw Sexp
   │  src/reader.zig      normalize to the canonical Form schema, merge ^meta,
   ▼                      lower #(), drop #_; pretty-printer; goldens
Form  {datum, origin, user_meta, ann}
   │  src/expand.zig      per-form-rule walker: host macros (18, Zig-implemented:
   ▼                      let fn defn loop when when-not and or cond -> ->> case
                          condp for defrecord defprotocol extend-type extend-protocol),
                          user defmacro in a compile-time sub-VM, syntax-quote with
                          auto-gensym, qualified macro heads, (ns ...) and require
expanded Form
   │  src/compile.zig     lowerForm → Tiny IR → 64-bit bytecode; capture analysis
   ▼                      is a pre-pass; Vars are identity-stable heap cells and
                          global calls go through Var indirection
bytecode
   │  src/vm.zig          slot VM, group-based opcode dispatch, closures, recur,
   ▼                      letfn*, try/catch/finally, reentrant callValue
value
```

The three representations — Form, Value, Encoded — fuse only through
the codec (PLAN §5). Compile errors carry `file:line:col` and a source
caret; a symbol that names nothing is `UnresolvedSymbol` at its own
span. Runtime errors and reader errors carry no location (§6).

### 3.2 The value model

`src/value.zig`: a 16-byte tagged `Value` with a `Kind` byte.
Immediates: `nil`, `false_`, `true_`, `char`, `fixnum` (48-bit
payload, `fixnum_max = 2^47 - 1`), `float`, `keyword`, `symbol` (both
interned ids). Heap kinds, by number: `string 16`, `bignum 17`,
`persistent_map 18`, `persistent_set 19`, `persistent_vector 20`,
`list 21`, `byte_vector 22` and `typed_vector 23` (reserved, no
implementation), `function 24`, `var_ 25`, `durable_ref 26`,
`transient 27`, `error_ 28`, `meta_symbol 29`, `native_fn 30`,
`db_connection 31`, `db_write_txn 32`, `db_read_txn 33`, `atom 34`,
`record 35`, `protocol 36`, `protocol_fn 37`, `nextomic_conn 38`,
`nextomic_db 39`; 40-63 are free. A new kind adds an enum value and
arms in `dispatch.zig` (equality, hash, category), `format.zig`,
`gc.zig` and `codec.zig`; `nextomic_handle` is the pattern for a kind
whose body lives above `dispatch`.

Numbers: fixnum, bignum and f64 with Clojure contagion. An integer
result outside i48 is a bignum and one that fits is a fixnum again
(`src/bignum.zig` over `std.math.big.int`, `docs/BIGNUM.md` §9), so
`=` and `hash` agree for every integer; integer literals of any size
read and print in decimal; `(= 1 1.0)` is false, `(== 1 1.0)` true;
`/` on two integers yields a float when inexact; `:divide-by-zero`
is a catchable keyword; `long` and `double` convert.

Equality and hash (`docs/SEMANTICS.md`): list, vector and seq are one
sequential category, map and set their own; keyword and symbol hash
domains are separated; metadata never affects either.

### 3.3 Collections, heap, collector

`src/coll/champ.zig` (map and set), `src/coll/vector.zig` (plain
32-way trie with tail; `conj` and `assoc` are O(log n)),
`src/coll/list.zig`, `src/coll/transient.zig`. `src/heap.zig` owns the
blocks; the VM's `Heap` is backed by `VM.runtime_arena`, and closures,
Vars and upvalue cells are raw arena allocations. `src/gc.zig` is a
precise mark-sweep collector with caller-supplied roots; it passes
its property tests and **no allocation path ever calls
`Collector.collect`**, so a process grows until it exits (§6.1).

### 3.4 The db seam

`src/db.zig` (`docs/DB.md`) owns the `emdb.Env` behind a
`db.Connection`, pins `pageSize = 16384` and `maxNamedTrees = 128`
(the page size is fixed for a file's life and the Linux engine
default is 4 KiB), resolves tree ids once per connection, reads whole
values off cursors, and names every engine failure as a `:db/*`
keyword. Nextomic borrows the `Env` from a `db.Connection` and holds
raw `*emdb.Txn` handles and byte keys; the two layers share the
engine and the `:db/*` names and nothing else.

### 3.5 Nextomic

`src/nextomic/` is one build module above `dispatch` and `vm`,
imported by `stdlib` only. Files, one sentence each:

| file | role |
|---|---|
| `root.zig` | module root; re-exports |
| `key.zig` | sortable value encodings and index key layout: one tag byte orders types, byte order equals value order within a type, ids are 6-byte big-endian, attributes 4-byte, `top = (t << 1) \| added`; `v` is always followed by fixed-width fields so it carries no length |
| `datom.zig` | the `Datom` struct and the txlog entry codec |
| `store.zig` | `Env` ownership, the eleven `TreeId`s opened in one bootstrap transaction, `sys` counters, bootstrap ids, raw put/delete/scan and the `FoldScan` that implements as-of/since/history as one window over the history trees |
| `idents.zig` | durable keyword ↔ id mapping with a per-connection cache; a transaction's mints wait in a `Minter` and publish after commit |
| `schema.zig` | attributes as-of a basis, built from the attribute partition's datoms; per-attribute counts for the planner |
| `transact.zig` | the transaction protocol: begin, normalise, tempids, expand, schema checks, write, commit; the overlay model that makes implicit retracts and same-transaction unique claims O(1) |
| `db.zig` | `Conn` and `DbValue`; entity, entid/ident, datoms, tx-range; a speculative `with` is a second `Conn` over the held write transaction |
| `handle.zig` | heap bodies of `nextomic_conn` and `nextomic_db`; its own build module `nextomic_handle` below `dispatch`/`format`/`gc` |
| `marshal.zig` | VM values to and from datom values: the entity, value and cell contracts shared by natives, query, pull and transactions |
| `relation.zig` | the columnar `Relation` of the query pipeline, arena-scoped, never a VM value; hash join, difference, union |
| `query.zig` | the query pipeline's root: `q` opens one read, runs parse → plan → exec in one arena, closes on every path |
| `query/ir.zig` | the parsed query: pure syntax over the VM's symbol table, cacheable across dbs |
| `query/parse.zig` | query value → IR, with clause-indexed `:nextomic/query-syntax` diagnostics |
| `query/plan.zig` | greedy selectivity ordering against one read; index choice from the §5 table; constants pre-encoded |
| `query/exec.zig` | runs the plan: index nested loop or hash join per step, built-in predicates, user functions through the `CallHook` (`vm.callValue`) |
| `query/rules.zig` | rule expansion; recursive components run the semi-naive fixpoint |
| `query/natives.zig` | `q` and `explain`; the per-VM IR and rule-set caches |
| `pull.zig` | pull patterns over one read: `*`, nesting, reverse refs, recursion, `:limit`/`:default`/`:as` |
| `natives.zig` | the `nextomic` namespace table, `errorKeyword` (every error variant has a keyword; a test asserts totality), error payload maps, connection lifetime |

Key invariants (`docs/NEXTOMIC.md` §1): datoms are bytes-only keys
whose order is the index order; current and history trees are
separate; `t` is Nextomic's own monotonic counter in `nx/sys`, never
the engine's `txnId`; a db-value is a plain value `{store, basis,
mode}` with no open read transaction, and every operation opens a
pooled read for its own duration; integer entity ids in partitions
(attributes and idents `1 .. 2^32-1`, user entities from `2^32`,
transaction entities `2^46 | t`); schema is datoms read as-of the
basis; `q` is a native over a query value, cached per VM by heap
identity then structural hash; every operation allocates in its own
arena and copies only results into the VM heap; a Nextomic-semantic
error is a map `{:error :nextomic/... ...}` whose other keys carry the
context, or the bare keyword when there is nothing more to say.

### 3.6 Namespaces available without a file

| namespace | contents |
|---|---|
| `nexis.core` (auto-referred) | 139 natives in `src/stdlib.zig` `core_fns` (sequences, HOFs, collections, arithmetic, predicates, strings, I/O) plus 43 definitions in `src/stdlib/core.nx`: 16 macros (`when-let if-let dotimes with-tx with-read-tx with-snapshot declare if-not while letfn doseq cond-> cond->> some-> some->> as->`) and 27 functions (`true? false? second third last reverse take drop constantly complement partial comp every? not-every? some not-any? merge update get-in assoc-in update-in frequencies group-by interpose juxt fnil merge-with`) |
| `db` | 23 natives: `open close ref ref? put-key! get-key delete-key! present? begin-write begin-read commit! abort-write! abort-read! put! get delete! deref alter! scan reduce-tree snapshot release-snapshot! snapshot?` |
| `nexis.string` | `lower-case upper-case trim split join replace` |
| `nexis.internal` | the nine `#%...` primitives `defrecord`/`defprotocol` expand to |
| `nextomic` | 20 natives: `connect release db basis-t transact! entity entid ident datoms as-of since history tx-range schema sync q explain pull pull-many with`, plus the macro `with-conn` from `src/stdlib/nextomic.nx` |
| `user` | the current namespace at start |

`src/cli.zig` `bootRuntime` installs the tables, bootstraps `core.nx`
into `nexis.core` and `nextomic.nx` into `nextomic`, and gives both
`run` and `repl` one `Runtime`.

---

## 4. The contracts, and where they live

**Authority order** (`AGENTS.md`): `PLAN.md` §23 frozen decisions;
then PLAN Appendix C / §28 (the canonical Form schema); then
`docs/*.md`, which are derivative and must track PLAN; then code
comments. When sources disagree, the higher one wins and the lower one
is fixed in the same commit. A §23 decision changes only through a
dated entry in the Amendment Log at the end of `PLAN.md`; per-doc
amendment logs (`docs/COMPILER.md` §13, `docs/VM.md` §18, `ATOM.md`,
`PROTOCOLS.md`, `PERF.md` §11) record the downstream detail. The
Amendment Log is the one place dates belong outside commit messages.

**Nextomic**: `docs/NEXTOMIC.md` is authoritative for everything under
`src/nextomic/` and the `nextomic` namespace: §2 store layout, §3
transactions, §4 db-values and time, §5 query pipeline, §6 Lisp API,
§7 errors, §8 module layout, §11 what is not asked of the engine.
The engine-side note `../emdb/NEXTOMIC.md` is the maintainers' view of
emdb and its §1 is the reader's introduction to Datomic; where it
describes Nextomic it differs from the shipped design in three places
(it takes the basis from the engine `txnId`, has a db-value hold a
read transaction, and counts eight trees with a wider key layout);
`docs/NEXTOMIC.md` wins on each, and that note is edited only from the
emdb repository.

**The engine**: `../emdb/SPEC.md` (the invariant catalogue: INV-*,
API-*) and `../emdb/PERFORMANCE.md` are the contracts Nextomic's
design cites by name (page size and key bound, cursor value clamping,
one writer, tree registration, sync modes, `delPrefixFromTree`).

**The owner's rules**:

- **Zero changes to emdb.** Anything the engine seems to lack is
  solved on the nexis side. The "emdb wants" list is two items,
  both worked around (`docs/NEXTOMIC.md` §11): a transaction id
  accessor (Nextomic reads its own `t` from `sys` inside the same
  snapshot instead) and full multi-page values off a cursor (index
  trees carry only `[t]` or nothing; payloads and txlog entries are
  read with `Txn.getFromTree` on the exact key, which assembles every
  page). `../emdb/NEXTOMIC.md` §6 lists the temptations to refuse.
- **Timeless code and comments.** Describe what is. No "now",
  "previously", "used to", phase or turn numbers, or era framing in
  code, comments or docs; a review treats such phrasing as a defect.
  Delete the old thing rather than narrate the transition.
- **No AI attribution lines** in commits, pull requests or comments,
  whatever a harness suggests.
- **Every behaviour change starts with a failing test**: an inline
  `test` block for a structural invariant, a `test/prop/*` sweep for
  a statistical law, a corpus case for query or pull, a `.nx` script
  line and its `.out` for anything a program can see.
- **The full gate before every commit** (`zig build test --summary
  all`), the quick step in the loop.
- **Spec first** for anything substantive: the governing doc section
  is written or amended in the same commit as the code.
- Read the actual Clojure source and the actual Zig 0.16 stdlib
  before asserting what either does; `CLOJURE-REVIEW.md` records what
  the Clojure source settled, `ZIG-0.16.0.md` the APIs that differ
  from training data.
- Performance claims only from `zig build bench` in ReleaseFast under
  `docs/BENCH.md`; publish where Clojure wins too.

---

## 5. What is proven, and how

**Oracle corpora.** `test/integration/nextomic_q.zig` runs every query
twice: through parse → plan → exec, and through `Naive`, a
nested-loop evaluator over the view's datoms that knows nothing of
relations, plans or indexes; the sorted row sets must agree and each
query also pins a hand-counted row count. Rules in `Naive` run
bottom-up to a naive fixpoint, so the rule corpus uses a small graph
and the 5k-edge chain is checked against its known closure.
`test/integration/nextomic_pull.zig` runs every pattern through `pull`
and through a reference interpreter over `DbValue.entity` and
`DbValue.datoms`, on the current view, an as-of view and a `with`
view. `test/prop/nextomic_tx.zig` replays sixty random transactions
against an in-memory model that expands the §3 rules itself, checks
the report's datoms after each commit and, at the end, every basis
through every index plus `since` and `history`, across a reopen and
an aborted transaction. `test/prop/nextomic_key.zig` sweeps 100,000
random pairs per value type for `order(enc a, enc b) == cmp(a, b)`,
the NUL escape round trip, order across the inline threshold, and the
256-byte search-clue bound. `test/integration/nextomic_fx.zig` is the
fixture the corpora share.

**Scripts.** `test/nextomic/{basics,indexes,time,errors,query,pull,
with,with-conn,polish,persist-1,persist-2}.nx` run through
`bin/nexis` from a scratch directory that also holds `prelude.nx`;
each script's stdout must equal its `.out`. `persist-1` and
`persist-2` share one store across two processes. `polish.nx` pins
the behaviours the others do not: a function binding on a bound
variable, rule bodies of one name apart in the rule set, a wide
query, the pull cut at 1000, lookup refs and idents as `:in` inputs,
transaction entity ids as time arguments, the history view refusing
`entity` and `pull`, reverse refs and nested maps in map forms, unique
being card-one, cross-type comparisons, the error payload maps, and
`connect` making its directories.

**Language.** `test/integration/eval_pipeline.zig` runs source through
the whole pipeline for every primitive form, macro and
try/catch/finally path, and asserts after every run that the VM's
stack length and frame depth are restored (`expectStackRestored`);
`vm.zig` states the invariant once (every frame records
`entry_stack_len` and both return paths and `unwindThrow` shrink to
it) and the eval-pipeline harness is what enforces it.
`test/integration/runtime_polish.zig` pins the Clojure-fidelity rules
of the sequence library, records as maps, and the one policy for an
uncaught keyword throw from a native. `test/prop/*` (fifteen files)
sweep the collections, codec round trips, interning, heap and
collector; `src/*.zig` carry the inline unit tests; `test/golden/`
holds the reader goldens and eight reader-error cases.

**Review passes.** Three independent reviews (an analyst of declared
objectives against delivered code, an adversary of the design, an
architect of the ideal shape) drove the Nextomic build: the
current/history tree split, the logical `t`, the partitioned id
space, the sortable key encoding with its property test, the plain
db-value, `q` as a native, the arena-per-operation rule and the
page-size pin all answer findings from those passes. Three further
reviews (code quality, a Datomic user's probes, a Clojure-fidelity
sweep of the language) drove the polish: a function clause on an
already-bound variable unifies instead of panicking, lookup refs and
idents as `:in` inputs bind, reverse refs work in map forms, a nested
map under a plain ref must carry an identity, `:db/unique` on a
card-many attribute is refused, `since` and `tx-range` take a
transaction entity id, `entity` refuses a history view, an explicit
`:db/txInstant` stands, error payloads carry the attribute, value or
clause that failed, the marshalling lives in one module, the `/`
symbol survives a Value → Form round trip, a `def` anywhere in a form
declares its name, float `mod` is floored, vector `conj`/`assoc` are
O(log n), `(merge {} {})` is `{}`, `set`/`subvec`/`identical?` exist,
`(keys {})` is nil, `max` returns its operand, `get` reads strings,
and `vec` takes sets and maps. Review reports were used to drive the
polish; their findings are folded into tests. What they left open is
§6.

---

## 6. Known gaps

Each gap: symptom, cause, approach, the test that would prove it,
size. Nothing here is a data-corruption risk; the first bounds
process lifetime.

### 6.1 The collector is never invoked

*Symptom*: process memory grows without bound; a loader that
transacts millions of datoms in one process peaks in gigabytes.
Nextomic's own work is arena-scoped and freed per operation; the
tx-data a program builds, the reports and query results it holds live
in the VM heap and stay there.

*Cause*: `src/gc.zig` `Collector.collect` has callers only in its own
tests and `test/prop/{gc,transient}.zig`; `src/vm.zig` enumerates no
roots; closures, Vars and `UpvalCell`s are raw `runtime_arena`
allocations the collector cannot see; `gc.zig`'s mark switch panics
on `function`, `var_`, `error_`, `meta_symbol`, `byte_vector` and
`typed_vector` by design, so the collector cannot be switched on
until those kinds trace. `docs/GC.md` §9 pins the deferral.

*Approach*: (1) a rooting protocol — VM stack and frames, namespace
Vars, the interner, atom cells, open `db` and
`nextomic` handles, the per-VM Nextomic query and rule caches (which
hold query values by heap identity; `docs/NEXTOMIC.md` §5 says a
collector that frees or moves values must clear both), and a scoped
root set native functions push values onto before calling
`vm.callValue`; (2) move closures, Vars and cells onto the heap with
`trace` arms; (3) a byte counter in `Heap.alloc` and a threshold on
`Collector`. Nextomic needs nothing beyond cache clearing.

*Proof*: a `test/prop/gc.zig` case that runs a program allocating in
a loop under a small threshold and asserts a bounded high-water mark
and unchanged results; an `eval_pipeline` case where a native HOF
(`map`, `reduce`, `db/reduce-tree`, a query predicate) survives a
collection triggered inside its callback.

*Size*: `vm.zig`, `gc.zig`, `heap.zig`, `stdlib.zig`, `nextomic/
query/natives.zig`, `docs/GC.md`; on the order of a thousand lines.

### 6.3 Clojure surface gaps

Each is small and self-contained in `src/expand.zig`,
`src/compile.zig`, `src/stdlib.zig` or `src/stdlib/core.nx`; each
wants an `eval_pipeline` case that pins the Clojure result. Observed
through `bin/nexis`:

| gap | observed | where |
|---|---|---|
| `case` evaluates its keys | `(case 1 (1 2) :a :d)` → `NotCallable`; `(case 'x x :a :d)` → `UnresolvedSymbol` | `expand.zig` `expandCase` emits `(= g key)` with the raw key form; quote each key and turn a list key into an `or` of alternatives |
| syntax-quote gaps | `` `(~x ~@[2 3]) `` → `KindMismatch`; `` `{:a 1} `` → `MacroExpansionFailure`; `` `(+ 1 2) `` stays unqualified though PLAN §23 #29 promises qualification | `expand.zig` `expandSyntaxQuote*`: add map, set, quote and anon-fn payloads; seq the `#%concat` operands; decide qualification and either implement it or amend §23 #29 |
| multi-arity anonymous `fn` | `((fn ([x] x) ([x y] (+ x y))) 1 2)` → `MacroExpansionFailure` | `expandFnRename`; reuse `defn`'s arity dispatcher (`expandDefnMacro`) |
| finally-only `try`, keyword matchers | `(try 1 (finally 2))` → `MalformedForm`; `(catch :divide-by-zero e ...)` → `UnsupportedFeature` | `compile.zig` `lowerTry` requires one `catch any` |
| empty bodies and `()` | `((fn []))`, `(let [x 1])`, the literal `()` → `MalformedForm` | `compile.zig` (`items.len == 0` rejection); Clojure yields nil / `()` |
| `defn` docstrings and attr-maps | `(defn f "doc" [x] x)` → `MacroExpansionFailure` | `expandDefn` |
| destructuring extras | `{:strs [a]}`, `{:syms [a]}`, namespaced `:keys`, `& {:keys [a]}` keyword args, `loop` bindings | the destructuring expander (`:keys`/`:or`/`:as` at `expand.zig` ~2261) and `loop`'s binding path |
| `doseq` and `for` modifiers | `doseq` rejects `:when`/`:let`/`:while`; `for` has `:when`/`:let`, not `:while`, and does not destructure | `core.nx` `doseq`; `expand.zig` `expandFor` |
| `meta`/`with-meta`, `ex-info`/`ex-data`, `macroexpand`, `read-string`, `list*`, `reduced`, three-arity `fnil` | `UnresolvedSymbol` (`fnil` → `ArityMismatch`) | `stdlib.zig`; `reduced` needs the reducing natives to check for it; `read-string` needs the reader reachable from a native |
| symbols not callable | `('a {'a 1})` → `:not-callable` | `vm.zig` lookup arm; PLAN §23 #33 promises keywords only, so state or extend |
| reader errors carry no location | `nexis: parse error: ParseError` for `(println (1 2` | `src/cli.zig` reports compile errors with `file:line:col` and a caret; the reader path has no span; the golden `.err` files carry kinds like `:map-odd-count` that the CLI does not print |

### 6.4 Phase 5 as PLAN §21 defines it

*Symptom*: no test runner, no `nexis.test` (`deftest`/`is`/
`run-tests`), `nexis.math`, `nexis.pprint`; `bin/nexis` has `run`,
`repl` and `--help` only, no `--disasm`; runtime errors print
`nexis: runtime error: DivideByZero` with no source span or stack.

*Approach*: a PC → span table per Routine emitted by `compile.zig`,
read by the VM's error path and the CLI (`docs/COMPILER.md` and
`docs/VM.md` amendment logs); `nexis.test` in `core.nx` over `throw`
and atoms; `--disasm` walking a Routine's instructions with the
existing operand decoders. Refresh `src/cli.zig`'s usage text in the
same pass.

*Proof*: an `eval_pipeline` case asserting a runtime error's line and
column; a `.nx` script under `zig build examples` that defines tests
and runs them; a golden of `--disasm` output for `examples/sum10.nx`.

*Size*: `compile.zig`, `vm.zig`, `cli.zig`, `core.nx`; several
hundred lines each for spans and the runner.

### 6.5 Datalog function-position variables

*Symptom*: `[(?f ?x) ?y]` and `[(?pred ?x)]` are `:nextomic/
query-syntax`; the function position takes a symbol naming a function
(`docs/NEXTOMIC.md` §5, last sentence of "Execute").

*Approach*: `query/parse.zig` accepts a variable in function position;
`query/plan.zig` treats it as bound like any input; `query/exec.zig`
calls the cell's value through the `CallHook`.

*Proof*: corpus cases in `nextomic_q.zig` with `:in $ ?f` bound to a
`defn`'d function and to a keyword; a `.nx` line in `query.nx`; a
row in §5.

*Size*: three files, a few dozen lines each.

### 6.6 `typed_vector`

*Symptom*: `Kind.typed_vector = 23` is reserved with no constructor,
layout or natives; `nexis.simd` does not exist. PLAN §15.11 NX-2
expects `Relation` columns to share its representation; `relation.zig`
uses its own typed columns instead.

*Approach*: a heap kind with i64 and f64 columns, `trace`, `format`,
codec arms, `vec`/`nth`/`count`/`seq` over it; then kernels.

*Proof*: inline tests plus a `test/prop/typed_vector.zig` codec round
trip; the codec serializability matrix in `docs/CODEC.md` updated.

*Size*: a new `src/coll/typed_vector.zig` of a few hundred lines
plus arms in five files.

### 6.7 `^:dynamic` Vars and `binding`

*Symptom*: `(binding [x 2] x)` is `UnresolvedSymbol`; `(def ^:dynamic
x 1)` is `MacroExpansionFailure`, so the marker cannot even be
written. PLAN §21 Phase 3.7.

*Approach*: a dynamic-binding stack on the VM; `binding` as a macro
over push/pop with a `finally`; Var loads check the stack only for
Vars marked dynamic so ordinary loads stay one indirection.

*Proof*: `eval_pipeline` cases for nesting, a throw through
`binding`, and a closure capturing a dynamic Var seeing the binding
in force at call time.

*Size*: `vm.zig`, `compile.zig`, `core.nx`; a couple of hundred lines.

### 6.8 Nextomic follow-ups

In the order they unblock users; each wants its `docs/NEXTOMIC.md`
row, a corpus or `.nx` case and its `.out`:

- **A lazy entity kind**: `entity` returns an eager map read in one
  pass (`docs/NEXTOMIC.md` §6). An entity that reads attributes on
  access is a heap kind of its own, holding the connection, the basis
  and mode and the eid, with arms in `value.zig`'s `Kind`,
  `dispatch.zig` (lookup, `get`, `keys`, `seq`, `count`, equality by
  identity of connection, basis and eid), `format.zig`, `gc.zig` and
  the codec, and a `nextomic_handle.zig` body beside the two existing
  boxes. Each access opens a read transaction and folds the view, so
  `entity` on a history db can stay refused and a ref can return
  another lazy entity. The `.nx` scripts that print entity maps
  (`basics`, `polish`, `pull`, `time`) pin the eager shapes and would
  change.
- **Hash-join tuning**: the planner's estimates come from `treeStat`
  and per-attribute counts; `exec.zig` chooses nested loop when
  `rows × log n` is below the scan estimate. Measure
  `nextomic_q.zig`'s three-way joins in ReleaseFast before and after
  any change (`docs/PERF.md` §3.7).
- **Linux 4K-page run**: the page size is pinned in code, so a Linux
  run should produce byte-identical stores; there is no CI in this
  repository, so the proof is a run on a Linux host of `zig build
  test` plus a store written on one platform and read on the other.
- **A datom heap kind**: reads return `[e a v t added]` vectors.
- **Full-text over Unicode case**: `fulltext.zig` lowercases ASCII
  letters and keeps every non-ASCII byte as it is, so `Café` and
  `CAFÉ` are two tokens. Case folding beyond ASCII needs a table the
  runtime does not carry; adding one changes the rows the tokens tree
  holds, so it comes with a rebuild of the tree at open.

### 6.9 Smaller items

- `zig fmt --check` fails on `src/pool.zig`, `src/value.zig`,
  `src/golden.zig`, `src/nexis.zig` and the generated
  `src/parser.zig`; every other file under `src/` and `test/` is
  clean.
- `for` returns a vector, not a seq; `map`/`filter`/`reduce` are
  eager (PLAN §23 #14; a `stream` library is an open question).
- Not serializable (`:unserializable`): functions, vars, transients,
  namespaces, tx handles, records, protocols, the Nextomic handles.
- Reader edges: `1.` reads as a symbol; `:a/b/c` and `'a//b` are
  `ReaderFailure`; `\é` is a `ParseError` (`\u{HEX}` is the escape).
- Two connections to one file in one process work; their db-values at
  the same basis are unequal (equality is by connection identity).

---

## 7. How to work here

**Worktree per task.** `git worktree add ../nexis-wt-<name> -b <name>`
from the repository root; every worktree has its own `.zig-cache` and
`bin/`, and `../emdb` resolves from any of them. Merge to `main` as a
true merge, then delete the branch locally and remotely. Never
`--amend` or force-push anything published.

**Commits.** Short imperative subject with the area as prefix
(`nextomic:`, `stdlib:`, `compile:`, `vm:`, `docs:`, `test/nextomic:`),
a body that says what the behaviour is and cites the governing
section, split along logical lines, no attribution trailers. Spec and
test land in the same commit as the code.

**The gate.** `zig build quick` in the loop; `zig build nextomic-test`,
`nextomic-nx` and `examples` after touching `src/nextomic/`,
`stdlib.zig` or anything an example uses; `zig build test --summary
all` before every commit. If the tree does not build clean on arrival,
fix the environment before the first edit.

**Adding a native.** In `src/stdlib.zig`: a `NativeFn` descriptor
(`name`, `min_arity`, `max_arity` or `null` for variadic, `call`) and
an entry in the table of its namespace (`core_fns`, `db_fns`,
`string_fns`, `internal_fns`). The VM enforces arity; the function
receives `(vm, args)` and returns a `Value` or a `VmError`. Throw with
`vm.throwKeyword("name")` or `vm.throwValue(v)`; never hold a VM-heap
pointer across `vm.callValue` without rooting it (§6.1). Nextomic
natives go in `src/nextomic/natives.zig`'s table (or
`query/natives.zig` for query entry points) and wrap their body in a
`Scope` so the arena and read close on every path.

**Adding a `core.nx` macro or function.** `src/stdlib/core.nx` is
embedded with `@embedFile` and evaluated into `nexis.core` at boot
after the natives; a definition may use only what precedes it and
the natives. Macros here are user `defmacro`s and run in the
compile-time sub-VM; host macros (Zig) are registered in
`src/expand.zig`'s table.

**Adding a Nextomic tree or error.** A tree: `store.zig` `tree_names`
and `Trees`, a `docs/NEXTOMIC.md` §2 row, the `sys` format number if
the layout changes, and a bootstrap test. An error: a variant in the
explicit error set of the function that raises it, its keyword in
`natives.zig` `errorKeyword` (the totality test fails until it is
there), its payload keys in `failWith`'s `Detail`, a §7 row, and the
`.out` line that shows the map.

**Adding a `.nx` script.** Write `test/nextomic/<name>.nx` starting
with `(require '[nextomic :as d])` and `(require '[prelude :as t])`
for `t/check`, `t/caught`, `t/user-partition` and `t/tx-partition`;
add the name to the `scripts` list in `build.zig`'s `nextomic-nx`
block; produce the `.out` by running the script once from a scratch
directory that holds a copy of `prelude.nx` (`bin/nexis run
<name>.nx > <name>.out` with the scratch directory as cwd), read
every line before committing it, and
keep the store path relative so the build's scratch directory owns
it. A map prints in CHAMP trie order, which for keyword keys is a
function of each keyword's intern id: stable for a given script, not
alphabetical, and different when a key is interned earlier; sort
before printing when a line needs a readable order.

**Running one test binary.** `zig build quick --verbose` (or any test
step) prints each binary's command line as `.zig-cache/o/<hash>/test
--listen=-`; run that path with no arguments and it prints `All N
tests passed`. The binaries are Debug builds under
`std.testing.allocator`, which reports leaks.

**ReleaseFast.** `zig build -Doptimize=ReleaseFast install` builds
`bin/nexis` optimized in about 12 s warm; `-Doptimize=ReleaseFast`
applies to every step, so `zig build -Doptimize=ReleaseFast test`
runs the gate optimized and `NEXTOMIC_BENCH=1 zig build nextomic-test
-Doptimize=ReleaseFast --summary all` reproduces `docs/PERF.md` §3.7.
A Debug binary under the testing allocator is not a performance
measurement.

**Formatting.** `zig fmt --check <files you touched>`; the five files
in §6.9 are the only ones that fail, and `src/parser.zig` is generated
(`zig build parser` after any change to `nexis.grammar`; commit the
regenerated file with the grammar).

**Zig 0.16 traps** that have bitten this tree are listed in
`AGENTS.md`; `ZIG-0.16.0.md` has the rest.

---

## 8. Recommended order of work

1. **The collector (§6.1).** The largest gap and the one that bounds
   every long-running use, including a Nextomic loader. It touches
   the VM, the natives and the Nextomic caches, so it is best done
   before the natives multiply further; transaction functions (§6.8)
   wait on its rooting rule.
2. **Clojure surface gaps (§6.3), `case` and syntax-quote first.**
   Each is a morning's work with an obvious test; together they are
   most of what a Clojure programmer trips over in the first hour.
   `defn` docstrings, multi-arity `fn`, finally-only `try` and the
   conversions follow in whatever order the next program needs.
3. **Runtime source spans and the test runner (§6.4).** Once programs
   are longer than a screen, an unlocated `DivideByZero` is the
   worst remaining experience; the span table is the substrate for
   `nexis.test` output and for `--disasm`.
4. **Datalog function-position variables (§6.5)** and the query
   surface items in §6.8, driven by the first real query that needs
   them; each is a parse/plan/exec triple with a corpus case.
5. **Transaction functions and `:db.fn/cas`, then excision and
   full-text (§6.8).** Transaction functions unlock the next class
   of Nextomic programs; they come after 2 so the callback into the
   VM is safe by construction.
6. **`^:dynamic`/`binding` (§6.7) and `typed_vector` (§6.6)** when a
   user need appears; both are self-contained and neither blocks the
   rest.
7. **Performance pass** (PLAN §21 Phase 6, `docs/PERF.md` §6): Var
   inline caches, SIMD CHAMP nodes, zero-copy strings from emdb
   pages, hash-join tuning. Measure first with `zig build bench`;
   `docs/BENCH.md` is the honesty gate.

Take them in this order unless a user need reorders them; every item
starts with its spec section and its failing test.
