# nexis

> **Clojure language design on a Zig-native runtime, with a
> Datomic-class database inside.** Same surface syntax, same
> persistent collections, same macros, same lexical scoping. One
> static binary, no JVM, durable identity as a value kind, and
> Nextomic: immutable facts with time, Datalog, `as-of`/`since`/
> `history`, in one file. **Not a Clojure port** — no Java interop,
> no STM; the trade is spelled out below.

**nexis** takes Clojure's best ideas — persistent immutable collections,
macros, keywords, data-first APIs, identity/value separation, lexical
closures, `let`/`fn`/`defn`/`loop`/`recur` — and implements them on a
vertically integrated Zig substrate: a grammar-driven parser (`nexus`),
an mmap'd MVCC B+ tree storage engine (`emdb`), and a 64-bit bytecode
VM. Durable identities and Nextomic connections are first-class values,
not a library bolted on top.

## Status

Every row below is runnable through `bin/nexis`. `zig build test`
runs **1282 tests** across 135 build steps (unit, property, golden,
Nextomic corpora, and the `test/nextomic/*.nx` end-to-end scripts).
See [`PLAN.md`](PLAN.md) §21 for the phase map and
[`HANDOFF.md`](HANDOFF.md) for the ranked next-work list.

| Area | What ships |
|---|---|
| Reader | Grammar-driven parser, canonical Form schema, pretty-printer, golden tests |
| Runtime core | 16-byte tagged Value, CHAMP map/set, 32-way persistent vector, list, transients, bignum kind, codec, precise mark-sweep collector (`src/gc.zig`; see Known gaps) |
| Compiler + VM | Form → Tiny IR → 64-bit bytecode; slot VM with closures, `recur`, `letfn*`, try/catch/finally, catchable VM errors as keywords; a frame restores its entry stack length on return and unwind |
| Errors | Compile errors carry `file:line:col` and a source caret; a symbol that names nothing is `UnresolvedSymbol` at its own span |
| Macros | Host macros, user `defmacro` (compile-time sub-VM), syntax-quote with `~`/`~@`/auto-gensym, procedural macros over native fns, qualified macro heads (`alias/name`) |
| Namespaces | `(ns NAME)`, qualified symbols and keywords (`:person/name`), `require` with `:as`, ns-to-file loading, cycle detection |
| Numbers | Fixnum (48-bit) and f64 with Clojure contagion; `(= 1 1.0)` is `false`, `(== 1 1.0)` is `true`; `/` on two integers yields a float when inexact; `:divide-by-zero` and `:arithmetic-overflow` are catchable |
| Invocation | Keywords, maps, sets and vectors are callable: `(:a m)`, `(m :a)`, `(#{1 2} 2)`, `([10 20] 1)` |
| Destructuring | Sequential, associative, nested, `& rest`, `:as`, `:keys`, `:or` in `let`/`fn`/`defn`; multi-arity `defn`; `#(...)` shorthand |
| Core library | 162 native functions in `nexis.core` (`src/stdlib.zig`: sequences, HOFs, collections, arithmetic, predicates, strings, I/O) plus 44 macros and functions in `src/stdlib/core.nx` (`when-let`, `doseq`, `cond->`, `some->`, `as->`, `update-in`, `group-by`, `frequencies`, ...); `nexis.string` |
| Clojure breadth | Atoms (`atom`/`swap!`/`reset!`/`compare-and-set!`), `str`/`subs`/`print`/`println`/`slurp`/`spit`, records, protocols, `extend-protocol`/`extend-type`/`satisfies?`, `case`/`condp`/`for` |
| Durable refs (`db/*`) | Refs backed by emdb named trees: `db/open`/`db/ref`/`db/put-key!`/`db/get-key`, `with-tx`/`with-read-tx` with rollback on throw, `@deref`, `db/alter!`, `db/scan`, `db/reduce-tree`, MVCC snapshots via `with-snapshot`; page size pinned to 16 KiB, tree ids cached per connection, engine failures as named `:db/*` keywords |
| Nextomic | The `nextomic` namespace: `connect`/`release`/`db`/`basis-t`/`transact!`/`entity`/`entid`/`ident`/`datoms`/`as-of`/`since`/`history`/`tx-range`/`schema`/`sync`/`q`/`explain`/`pull`/`pull-many`/`with`, `with-conn`; every error catchable by `try` (the taxonomy is under Nextomic below). Spec: [`docs/NEXTOMIC.md`](docs/NEXTOMIC.md) |
| Tooling | `nexis run FILE.nx`, `nexis repl`, `zig build bench` (ReleaseFast harness, [`docs/BENCH.md`](docs/BENCH.md)), `zig build golden` |

## Build & run

```bash
zig build install                  # bin/nexis, bin/nexis-golden

./bin/nexis run examples/hello.nx  # run a file
./bin/nexis repl                   # interactive REPL
./bin/nexis --help                 # usage
```

For developers:

```bash
zig build quick                    # seconds — language, eval-pipeline and Nextomic unit + property binaries
zig build nextomic-test            # Nextomic unit, property and corpus tests
zig build nextomic-nx              # test/nextomic/*.nx through bin/nexis
zig build examples                 # every examples/*.nx through bin/nexis
zig build test --summary all       # minutes — everything (1282 tests)
zig build parser                   # regenerate src/parser.zig from nexis.grammar
zig build bench                    # ReleaseFast benchmark suite
```

See [`AGENTS.md`](AGENTS.md) for which step fits which loop.

## The language

Every snippet runs via `bin/nexis`:

```clojure
(let [x 5] ((fn [y] (+ x y)) 3))            ;; => 8
(loop [i 0 acc 0]
  (if (< i 10) (recur (+ i 1) (+ acc i)) acc)) ;; => 45  constant stack

(defmacro unless [test & body]
  `(if ~test nil (do ~@body)))
(unless false :got-it)                      ;; => :got-it

(let [{:keys [x y] :or {y 10}} {:x 5}] (+ x y)) ;; => 15
(defn arity ([x] :one) ([x y] :two) ([x y & r] :many))
(arity :a :b :c)                            ;; => :many

(:a {:a 1})                                 ;; => 1   keyword as function
(#{1 2} 2)                                  ;; => 2   set as function
(+ 1 2.5)                                   ;; => 3.5 contagion
(= 1 1.0)                                   ;; => false
(== 1 1.0)                                  ;; => true
(try (/ 1 0) (catch any e e))               ;; => :divide-by-zero

(ns my.app)
(defn double [x] (* x 2))
(ns user)
(my.app/double 21)                          ;; => 42
(require '[lib.geom :as g])                 ;; examples/lib/geom.nx
(g/area-of-square 5)                        ;; => 25

(defprotocol Area (area [s]))
(defrecord Square [side])
(extend-protocol Area Square (area [s] (* (:side s) (:side s))))
(area (->Square 3))                         ;; => 9

(def counter (atom 0))
(swap! counter inc)                         ;; => 1

;; durable refs — values persist across processes (examples/todo-app.nx)
(def conn (db/open :app.edb))
(def alice (db/ref conn :users :alice))
(with-tx [tx conn] (db/put! tx alice {:age 31}))
@alice                                      ;; => {:age 31}
(db/close conn)
```

Compile errors carry `file:line:col` and a source caret:

```text
$ echo '(when)' > bad.nx && bin/nexis run bad.nx
nexis: bad.nx:1:1: MacroExpansionFailure
    (when)
    ^^^^^^
```

## Nextomic

Nextomic is a Datomic-class database inside the binary. A fact is a
datom `[e a v t added]`; the store keeps every fact it ever learned;
a db-value is an immutable view at a basis `t`; `as-of`, `since` and
`history` are views of the same trees; queries are Datalog data; a
transaction is data too. One file on disk, no JVM, no server, and
zero changes to emdb — every index is an ordinary named tree of
byte keys whose lexicographic order is the index order. Current
facts live in four current trees; history in four more with the
transaction in the key; `nx/txlog`, `nx/idents` and `nx/sys` make
eleven.

From [`examples/nextomic-app.nx`](examples/nextomic-app.nx), a clinic
chart:

```clojure
(require '[nextomic :as d])

(def schema
  [{:db/ident :patient/mrn :db/valueType :db.type/string :db/cardinality :db.cardinality/one
    :db/unique :db.unique/identity :db/doc "Medical record number"}
   {:db/ident :patient/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
   {:db/ident :patient/allergies :db/valueType :db.type/keyword :db/cardinality :db.cardinality/many}])

(d/with-conn [c "tmp/clinic.edb"]
  (d/transact! c schema)
  (let [intake (d/transact! c [{:patient/mrn "MRN-1001" :patient/name "Mara Quist"
                                :patient/allergies [:penicillin]}])
        db     (d/db c)]
    (println "latex allergies:"
             (d/q '[:find [?name ...] :where [?p :patient/allergies :latex] [?p :patient/name ?name]] db))
    (println "Mara at intake:" (:patient/allergies (d/entity (d/as-of db (:tx intake)) [:patient/mrn "MRN-1001"])))))
```

The full example adds refs, component notes, a double-valued
attribute, joins with `:in` inputs, a predicate, an aggregate,
nested and reverse `pull` patterns, `history`/`tx-range`, a
speculative `with`, and a caught `:nextomic/unique`. It is safe to
run twice: upserts by unique identity make the second run a no-op.

What the query layer accepts: patterns, the `:in` forms `$`, scalar,
collection, tuple, relation and `%` rules (one database per query;
no `:keys`/`:strs`/`:syms`), predicates and function bindings that
call any Lisp function including one you `defn`'d, the aggregates
`min max sum avg count count-distinct distinct`, the find specs `.`,
`[...]`, `[[...]]` and relation, `not`/`not-join`/`or`/`or-join`/
`and`, recursive rules, and the time views. `(d/explain query db)` returns the plan as a string. Parsed
queries are cached per VM by value.

Two calls differ from Datomic's. `(d/with conn tx-data f)` is the
speculative transaction: it takes the connection, not a db-value,
and calls `f` with `db-after` and the report inside a held write
transaction that is aborted when `f` returns; Datomic's `(with db
tx-data)` returns the report instead. `(d/tx-range conn)`,
`(d/tx-range conn from)` and `(d/tx-range conn from to)` return the
log entries with `from <= t < to`; a `nil` or absent bound is open.

Errors are values a `try` catches. A Nextomic-semantic error is a
map whose `:error` names it and whose other keys carry the context:
`{:error :nextomic/unique :attr :patient/mrn :value "MRN-1001"}`,
`{:error :nextomic/query-syntax :message "..." :clause 2}`;
`(:error e)` is the classifier. An argument of the wrong shape is
the VM's own keyword — `:kind-mismatch` for a db-value where a
connection belongs, `:invalid-argument` for an unknown index or
option, `:arity-mismatch` — and an engine failure is the `db/*`
layer's keyword (`:db/open-failed`, `:db/corrupted`, ...).

On disk: `connect` creates the path's missing parent directories,
and a store file is a sparse 256 MB reservation that grows when it
fills, so `ls -l` reports the reservation and `du` the bytes in use.

`test/nextomic/{basics,indexes,time,errors,query,pull,with,with-conn,
persist-1,persist-2}.nx` are the executable specification; each
`.out` file is the expected stdout, and `query.nx` is the fastest
tour of the surface. [`docs/NEXTOMIC.md`](docs/NEXTOMIC.md)
is the authoritative design: §2 store layout, §3 transactions, §4
db-values and time, §5 query pipeline, §6 Lisp API, §7 errors, §8
module layout, §9 runtime prerequisites, §10 where Nextomic wins and
where it does not.

## Known gaps

Stated so nobody rediscovers them:

- **The collector is never invoked at runtime.** `src/gc.zig`
  implements precise mark-sweep and passes its property tests, but
  no allocation path calls `collect`; a long-running process grows
  without bound. Nextomic allocates in per-operation arenas, but the
  tx-data a program builds, the reports and the query results live
  in the VM heap and stay there, so a loader that transacts millions
  of datoms should batch the work into processes that exit and
  restart rather than run as one process. Wiring the collector needs
  a rooting protocol for native functions (see `HANDOFF.md`).
- **No bignum arithmetic.** The `bignum` kind, codec and hashing
  exist; arithmetic does not promote. Fixnum overflow raises
  `:arithmetic-overflow`; an integer literal outside ±2^47 is a
  compile error (`IntegerOutOfFixnumRange`; inside a macro call it is
  reported as `MacroExpansionFailure` over the whole form).
- **No `^:dynamic` Vars, no `binding`.** `(binding ...)` is an
  unresolved symbol.
- **Several Clojure core forms and functions are absent** (`case`
  with evaluated keys, finally-only `try`, multi-arity `fn`, `defn`
  docstrings, `:strs`/`:syms` destructuring, `int`/`long`/`double`,
  `ex-info`, `macroexpand`, `read-string`, ...); `HANDOFF.md` §4
  lists them.
- **No tooling layer** (PLAN §21, Phase 5): no test runner, no
  `nexis.test`/`nexis.math`/`nexis.pprint`, no `--disasm`, and
  runtime errors carry no source spans (stack traces are not
  source-mapped). The Clojure-breadth stdlib is listed in the status
  table.
- **`(vec #{...})` and `(vec {...})` raise `:kind-mismatch`**; `vec`
  accepts nil, vectors and lists. Use `(into [] s)`.
- **Datalog function-position variables** are unsupported: the
  function position of a predicate or function clause takes a
  symbol naming a function, never a `?var` bound to one
  (`docs/NEXTOMIC.md` §5).
- **`typed_vector`** is a reserved Value kind with no
  implementation; `nexis.simd` kernels do not exist.
- **Not serializable**: functions, vars, transients, namespaces,
  tx handles, records, protocols (`:unserializable`).
- **Nextomic follow-ups** (listed in `docs/NEXTOMIC.md` §6):
  transaction functions and `:db.fn/cas`, excision, full-text,
  lazy entities, a datom heap kind.

## Permanent differences from Clojure/JVM

These never close — they are trade-offs, not bugs:

- **No Java interop.** No `(Math/sqrt x)`, no `(.method obj)`, no
  `(import …)`. Roughly 30–40% of real-world Clojure code touches
  Java; that code does not port.
- **No STM** (`ref`, `dosync`, `commute`). Immutable values, atoms
  and durable transactions are the concurrency story. Single
  isolate, single thread.
- **No JVM ecosystem.** No Maven Central, no Leiningen. The library
  story rebuilds on top of nexis.

**The semantics port; the platform and the libraries don't.** A
Clojure programmer trades the JVM ecosystem for a single binary, no
JVM warmup, integrated durable storage, and a Datomic-class database
in the same process. That is a real trade, not a free lunch. See
[`CLOJURE-REVIEW.md`](CLOJURE-REVIEW.md) for the line-by-line
catalogue of what nexis takes, adapts, and rejects from Clojure's
source.

## What makes this different

| Dimension | Clojure-on-JVM | nexis |
|---|---|---|
| Host runtime | JVM (~150 MB resident, 1–3 s startup) | Zig-native binary, instant start |
| Compilation target | JVM bytecode | Custom 64-bit ISA ([`docs/VM.md`](docs/VM.md)) |
| GC | JVM (G1 / ZGC / etc.) | Precise mark-sweep, implemented but not wired (Known gaps) |
| Persistent collections | Bagwell HAMT + 32-way vector | CHAMP HAMT + 32-way vector |
| Concurrency | JVM threads + STM (Refs) | Single isolate; atoms; durable transactions |
| Java interop | Yes (huge) | None (intentional) |
| Durable storage | External (Datomic, JDBC, etc.) | In-process: emdb; `durable_ref`, `nextomic_conn`, `nextomic_db` are Value kinds |
| Temporal database | Datomic (separate product, JVM, transactor + storage service) | Nextomic in the same binary, one file, no emdb changes |
| Deployment | JVM uberjar / native-image | Static binary |

## What's here

| Path | Purpose |
|---|---|
| [`PLAN.md`](PLAN.md) | Authoritative design — read first (§21 roadmap, §23 frozen decisions + amendment log, §28 canonical Form schema) |
| [`HANDOFF.md`](HANDOFF.md) | Self-contained handoff: what exists, how to verify it, ranked next work |
| [`AGENTS.md`](AGENTS.md) | Routing guide for contributors / AI sessions |
| [`CLOJURE-REVIEW.md`](CLOJURE-REVIEW.md) | What nexis takes, adapts, rejects from Clojure's source |
| [`docs/`](docs/) | Design specs — [`docs/README.md`](docs/README.md) maps module ↔ spec; [`docs/NEXTOMIC.md`](docs/NEXTOMIC.md) is the database |
| [`src/`](src/) | Zig modules: `vm.zig`, `compile.zig`, `expand.zig`, `stdlib.zig`, `db.zig`, `coll/`, `nextomic/` (`key`, `datom`, `store`, `idents`, `schema`, `transact`, `db`, `relation`, `query/{ir,parse,plan,exec,rules}`, `pull`, `natives`, `handle`) |
| [`stdlib/`](src/stdlib/) | `core.nx` and `nextomic.nx`, embedded at build time |
| [`test/`](test/) | `prop/` property tests, `integration/` corpora (`nextomic_q.zig`, `nextomic_pull.zig`), `golden/` reader tests, `nextomic/` end-to-end scripts; most unit tests are inline in `src/*.zig` |
| [`examples/`](examples/) | Working `.nx` programs — see [`examples/README.md`](examples/README.md) |
| [`nexis.grammar`](nexis.grammar) | Reader grammar — source of truth for `src/parser.zig` |
| [`ZIG-0.16.0.md`](ZIG-0.16.0.md) | Zig 0.16 stdlib reference + gotchas (mandatory before writing Zig) |

## Requirements

- **Zig 0.16.0** (pinned). See [`ZIG-0.16.0.md`](ZIG-0.16.0.md).
- **nexus** at `../nexus/bin/nexus` for `zig build parser`.
- **emdb** as a path dependency (see `build.zig.zon`). Nextomic
  opens every store with `pageSize = 16384`; on Linux, where the
  engine default is 4 KiB, the pin is what keeps files portable.

## License

TBD (v1 ships under a permissive license).
