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
FILE.nx` and `bin/nexis repl` run real programs (`bin/nexis disasm
FILE.nx` shows their bytecode): `defn`, `defmacro`,
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
`nx/idents`, `nx/sys` and `nx/fulltext` complete twelve named trees
in one file. One
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
zig build test --summary all      # the gate: 1476 tests, 157 steps, ~4 min wall
```

The gate's last line reads `Build Summary: 157/157 steps succeeded;
1472/1476 tests passed`, preceded by `golden: ok=11 updated=0
failed=0 missing=0`. Two integration binaries end with a benchmark
whose row-count checks always run; the build runner echoes their
stderr as `failed command:` lines while both succeed, so read the
summary line, not the noise.

The build steps, and what each is for:

| step | runs | time (warm, Debug) |
|---|---|---|
| `zig build quick` | the language binaries (`vm`, `compile`, `expand`, `stdlib`, `loader`, `disasm`, `atom`, `record`, `protocol`, `format`), the compile property tests, `test/integration/{eval_pipeline,runtime_polish,numbers}.zig`, the Nextomic unit binary and its two property tests | ~35-50 s |
| `zig build nextomic-test` | `src/nextomic/*` unit tests, `test/prop/nextomic_{key,tx}.zig`, `test/integration/nextomic_{q,pull}.zig` | ~33 s |
| `zig build nextomic-nx` | every `test/nextomic/*.nx` through `bin/nexis`, stdout diffed against its `.out` | seconds |
| `zig build examples` | every `examples/*.nx` through `bin/nexis`; `durable-refs`, `todo-app` and `nextomic-app` twice | seconds |
| `zig build golden` | reader goldens (`-Dupdate=true` rewrites them) and the CLI goldens under `test/golden/cli` (a runtime error's stderr, a disassembly, a `pprint` script's stdout, pinned byte for byte) | seconds |
| `zig build test --summary all` | all of the above plus every module's inline tests and the randomized collection gates | ~4 min |
| `zig build bench` | the ReleaseFast benchmark harness (`docs/BENCH.md`) | minutes |
| `zig build parser` | regenerates `src/parser.zig` from `nexis.grammar` via `../nexus/bin/nexus` | seconds |

One environment variable, `NEXIS_GC_STRESS`: when set, every VM collects every 4 KiB of
allocation instead of every 16 MiB (`NEXIS_GC_STRESS=1 zig build test
--summary all` proves the natives' rooting; `docs/GC.md` §7). Debug
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
span; a parse or reader failure is reported the same way, at the
token or form the reader rejected. A runtime error is reported at
the instruction that raised it through each routine's PC → span
table, with the frame chain the VM recorded (`docs/TOOLING.md` §1).

### 3.2 The value model

`src/value.zig`: a 16-byte tagged `Value` with a `Kind` byte.
Immediates: `nil`, `false_`, `true_`, `char`, `fixnum` (48-bit
payload, `fixnum_max = 2^47 - 1`), `float`, `keyword`, `symbol` (both
interned ids). Heap kinds, by number: `string 16`, `bignum 17`,
`persistent_map 18`, `persistent_set 19`, `persistent_vector 20`,
`list 21`, `byte_vector 22` (reserved, no implementation),
`typed_vector 23` (unboxed `i64` / `f64` elements,
`docs/TYPED_VECTOR.md`), `function 24`, `var_ 25`, `durable_ref 26`,
`transient 27`, `error_ 28`, `meta_symbol 29`, `native_fn 30`,
`db_connection 31`, `db_write_txn 32`, `db_read_txn 33`, `atom 34`,
`record 35`, `protocol 36`, `protocol_fn 37`, `nextomic_conn 38`,
`nextomic_db 39`, `nextomic_entity 40`; 41-63 are free. A new kind
adds an enum value and arms in `dispatch.zig` (equality, hash,
category), `format.zig`, `gc.zig` and `codec.zig`; `nextomic_handle`
is the pattern for a kind whose body lives above `dispatch`.

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
blocks and counts the bytes; every runtime value, closure and upvalue
cell is a block on the VM's `Heap`, while Vars and namespaces are
immortal arena objects. `src/gc.zig` is a precise, non-moving
mark-sweep collector whose host is the VM (`docs/GC.md` §3, §7):
`VM.gcRoots` enumerates the stack, frames, Vars, binding stack, root
stack and pending throws, and a cycle runs at the instruction-fetch
safe point once the heap has allocated its threshold (16 MiB or the
live size, whichever is larger; `NEXIS_GC_STRESS=1` makes it 4 KiB
for every VM). A native that keeps a callback's result across a
further call back into the VM pushes it on a `vm.rootScope()` first.

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
| `store.zig` | `Env` ownership, the twelve `TreeId`s opened in one bootstrap transaction, `sys` counters, bootstrap ids, raw put/delete/scan and the `FoldScan` that implements as-of/since/history as one window over the history trees |
| `idents.zig` | durable keyword ↔ id mapping with a per-connection cache; a transaction's mints wait in a `Minter` and publish after commit |
| `schema.zig` | attributes as-of a basis, built from the attribute partition's datoms; per-attribute counts for the planner |
| `transact.zig` | the transaction protocol: begin, normalise, tempids, expand, schema checks, write, commit; the overlay model that makes implicit retracts and same-transaction unique claims O(1) |
| `excise.zig` | excision: the deletes across every tree and the txlog rewrite that leaves `{:excised [...]}` markers (`docs/NEXTOMIC.md` §4) |
| `fulltext.zig` | the tokenizer and the `nx/fulltext` rows: put, delete, search |
| `db.zig` | `Conn` and `DbValue`; entity, entid/ident, datoms, tx-range; a speculative `with` is a second `Conn` over the held write transaction |
| `handle.zig` | heap bodies of `nextomic_conn`, `nextomic_db` and `nextomic_entity`; its own build module `nextomic_handle` below `dispatch`/`format`/`gc`/`vm`, whose `lookup` reads a lazy entity through the hook its box carries |
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
| `natives.zig` | the `nextomic` namespace table, `errorKeyword` (every error variant has a keyword; a test asserts totality), error payload maps, connection lifetime, the lazy entity's access paths (`entityLookup`, `entityHas`, `entityMap`) |

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
| `nexis.core` (auto-referred) | 164 natives in `src/stdlib.zig` `core_fns` (sequences, HOFs, collections, arithmetic, predicates, strings, I/O, dynamic bindings, the compiler at run time: `macroexpand-1 macroexpand read-string eval`) plus 48 definitions in `src/stdlib/core.nx`: 18 macros (`when-let if-let dotimes with-tx with-read-tx with-snapshot binding doc declare if-not while letfn doseq cond-> cond->> some-> some->> as->`) and 30 functions (`true? false? second third last reverse take drop unreduced ensure-reduced constantly complement partial comp every? not-every? some not-any? merge update get-in assoc-in update-in frequencies group-by interpose juxt vary-meta fnil merge-with`) |
| `db` | 23 natives: `open close ref ref? put-key! get-key delete-key! present? begin-write begin-read commit! abort-write! abort-read! put! get delete! deref alter! scan reduce-tree snapshot release-snapshot! snapshot?` |
| `nexis.string` | `lower-case upper-case trim split join replace` |
| `nexis.simd` | the typed-vector kernels `sum dot scale map` over `i64-vector` / `f64-vector` values (`docs/TYPED_VECTOR.md` §7.2); `(require '[nexis.simd :as tv])` aliases it |
| `nexis.internal` | the twelve `#%...` primitives `defrecord`/`defprotocol`/`try`/`deftest`, keyword arguments and syntax-quote expand to |
| `nexis.test` | `deftest is testing run-tests run-all-tests` and the registry and reporter they share, in `src/stdlib/test.nx` (`docs/TOOLING.md` §3) |
| `nexis.pprint` | `pprint pprint-str` in `src/stdlib/pprint.nx` (`docs/TOOLING.md` §4) |
| `nexis.math` | 5 natives `sqrt pow floor ceil round` plus `PI` and `E` from `src/stdlib/math.nx` (`docs/TOOLING.md` §4) |
| `nextomic` | 24 natives: `connect release db basis-t transact! excise! entity touch entity-db entid ident datoms index-range as-of since history tx-range schema sync q explain pull pull-many with`, plus the macro `with-conn` from `src/stdlib/nextomic.nx` |
| `user` | the current namespace at start |

`src/cli.zig` `bootRuntime` installs the tables, bootstraps `core.nx`
into `nexis.core`, `nextomic.nx` into `nextomic`, `test.nx`,
`pprint.nx` and `math.nx` into their namespaces, and gives `run`,
`repl` and `disasm` one `Runtime`.

---

## 4. The contracts, and where they live

**Authority order** (`AGENTS.md`): `PLAN.md` §23 frozen decisions;
then PLAN Appendix C / §28 (the canonical Form schema); then
`docs/*.md`, which are derivative and must track PLAN; then code
comments. When sources disagree, the higher one wins and the lower one
is fixed in the same commit. A §23 decision changes only through a
dated entry in the Amendment Log at the end of `PLAN.md`; the only
per-doc record is `docs/PERF.md` §11, the provenance of each
measurement. The Amendment Log is the one place dates belong outside
commit messages.

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
  solved on the nexis side (`docs/NEXTOMIC.md` §11: Nextomic reads
  its own `t` from `sys` rather than the engine's transaction id).
  `../emdb/NEXTOMIC.md` §6 lists the temptations to refuse.
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
fixture the corpora share. `test/integration/nextomic_fn.zig` runs
transaction functions, `:db.fn/cas`, schema alteration, excision and
full-text end to end. `test/integration/nextomic_entity.zig` runs
programs against a VM with `nextomic` installed: every access path of
the lazy entity, refs navigating, `touch`, identity, a released
connection, and an entity kept in a Var under the collector's stress
policy.

**Scripts.** `test/nextomic/{basics,indexes,time,errors,query,pull,
with,with-conn,polish,datoms,persist-1,persist-2,gc}.nx` run through
`bin/nexis` from a scratch directory that also holds `prelude.nx`;
each script's stdout must equal its `.out`. `persist-1` and
`persist-2` share one store across two processes. `polish.nx` pins
the behaviours the others do not: a function binding on a bound
variable, rule bodies of one name apart in the rule set, a wide
query, the pull cut at 1000, lookup refs and idents as `:in` inputs,
transaction entity ids as time arguments, the history view refusing
`entity` and `pull`, reverse refs and nested maps in map forms, unique
being card-one, cross-type comparisons, the error payload maps, an
entity reading on access, and `connect` making its directories.

**Language.** `test/integration/eval_pipeline.zig` runs source through
the whole pipeline for every primitive form, macro and
try/catch/finally path, and asserts after every run that the VM's
stack length and frame depth are restored (`expectStackRestored`);
`vm.zig` states the invariant once (every frame records
`entry_stack_len` and both return paths and `unwindThrow` shrink to
it) and the eval-pipeline harness is what enforces it.
`test/integration/runtime_polish.zig` pins the Clojure-fidelity rules
of the sequence library, records as maps, and the one policy for an
uncaught keyword throw from a native. `test/prop/*` (sixteen files)
sweep the collections, codec round trips, interning, heap and
collector; `src/*.zig` carry the inline unit tests; `test/golden/`
holds the reader goldens, eight reader-error cases and, under
`cli/`, the CLI's output for two runtime errors, a disassembly and
a `pprint` script, compared byte for byte by `zig build golden`.
`test/integration/eval_pipeline.zig` also asserts the line, column
and frame names a runtime error records and the counts and report
lines of `nexis.test`; `src/disasm.zig`'s tests walk every opcode
enum so a variant cannot exist without a listing name.

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
and `vec` takes sets and maps. The review findings behind the polish
are folded into tests. What they left open is §6.

---

## 6. Known gaps

Each gap: symptom, cause, approach, the test that would prove it,
size. Nothing here is a data-corruption risk.

### 6.1 Clojure surface gaps

Each is small and self-contained in `src/expand.zig`,
`src/compile.zig`, `src/stdlib.zig` or `src/stdlib/core.nx`; each
wants an `eval_pipeline` case that pins the Clojure result. Observed
through `bin/nexis`:

| gap | observed | where |
|---|---|---|
| symbols not callable | `('a {'a 1})` → `:not-callable` | `vm.zig` lookup arm; PLAN §23 #33 promises keywords only, so state or extend |
| macros receive only their arguments | no `&form`/`&env` (PLAN §23 #34) | `expand.zig` `callUserMacro` passes the arg forms as values; `macroexpand-1` at run time has no lexical environment to offer either |

### 6.2 Nextomic follow-ups

In the order they unblock users; each wants its `docs/NEXTOMIC.md`
row, a corpus or `.nx` case and its `.out`:

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

### 6.3 Smaller items

- `zig fmt --check` fails on the generated `src/parser.zig`; every
  other file under `src/`, `test/` and `build.zig` is clean.
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
`string_fns`, `internal_fns`, `math_fns`, `simd_fns`). The VM enforces arity; the function
receives `(vm, args)` and returns a `Value` or a `VmError`. Throw with
`vm.throwKeyword("name")` or `vm.throwValue(v)`; a callback result
kept across a further `vm.callValue` goes on a `vm.rootScope()`
first (`docs/GC.md` §11.5). Nextomic
natives go in `src/nextomic/natives.zig`'s table (or
`query/natives.zig` for query entry points) and wrap their body in a
`Scope` so the arena and read close on every path.

**Adding a `core.nx` macro or function.** `src/stdlib/core.nx` is
embedded with `@embedFile` and evaluated into `nexis.core` at boot
after the natives; a definition may use only what precedes it and
the natives. `test.nx`, `pprint.nx` and `math.nx` follow it into
their own namespaces and may use all of `nexis.core`; none of the
four may hold a keyword literal (`src/stdlib.zig` `CORE_NX_SOURCE`
says why). Macros here are user `defmacro`s and run in the
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
runs the gate optimized and `zig build bench -Doptimize=ReleaseFast
-- --filter nextomic` reproduces `docs/PERF.md` §3.7.
A Debug binary under the testing allocator is not a performance
measurement.

**Formatting.** `zig fmt --check <files you touched>`; the generated
`src/parser.zig` is the only file that fails, and it is generated
(`zig build parser` after any change to `nexis.grammar`; commit the
regenerated file with the grammar).

**Zig 0.16 traps** that have bitten this tree are listed in
`AGENTS.md`; `ZIG-0.16.0.md` has the rest.

---

## 8. Recommended order of work

1. **Performance** (PLAN §21 Phase 6, `docs/PERF.md` §6): the
   remaining levers are the GC and memory-footprint benchmark rows,
   generational GC, opcode specialization and inline caches at call
   sites, and node-owner transients. `docs/PERF.md` §3.8 holds the
   M5 rows for the dispatch loop and CHAMP lookup, and §6 the
   measured dead ends (frame pointer across instructions, string
   copies out of index keys, a measured planner `refs_per_value`,
   keyword-key monomorphization of assoc and conj) so they are not
   re-tried without a new row. Measure first with `zig build bench`;
   `docs/BENCH.md` is the honesty gate.

Take them in this order unless a user need reorders them; every item
starts with its spec section and its failing test.
