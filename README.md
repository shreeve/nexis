# nexis

> **Clojure's language on a Zig-native runtime, with a Datomic-class
> database inside.** Persistent collections, macros, keywords,
> destructuring and lexical closures as Clojure has them; one static
> binary that starts instantly; durable identity as a value kind; and
> Nextomic, immutable facts with time, Datalog, `as-of`, `since` and
> `history`, in one file. **Not a Clojure port**: no Java interop, no
> STM, one isolate, one thread.

nexis is a reader, a macroexpander, a compiler to 64-bit bytecode, a
slot VM, persistent collections (CHAMP maps and sets, 32-way vectors,
lists, transients), a 16-byte tagged value and a precise mark-sweep
collector, all in Zig 0.16. Under it sit two sibling projects: **emdb**,
a memory-mapped MVCC B+ tree storage engine, and **nexus**, the parser
generator that builds the reader's grammar.

## Build and run

Zig 0.16.0 and a sibling checkout of emdb (`../emdb`) are required.

```bash
zig build install                      # bin/nexis and bin/nexis-golden

./bin/nexis run examples/hello.nx      # run a file (also: bin/nexis FILE.nx)
./bin/nexis -e '(reduce + (range 101))'  # evaluate an expression: 5050
echo '(println :hi)' | ./bin/nexis run -  # a program from stdin
./bin/nexis repl                       # read-eval-print loop; :quit or Ctrl-D exits
./bin/nexis test my_tests.nx           # run files, then every deftest they define
./bin/nexis disasm examples/sum10.nx   # every routine's bytecode with source positions
./bin/nexis --help
```

`nexis run` prints only what the program prints; the REPL and `-e`
print each value. Exit status is 0 on success, 3 for a parse or reader
error, 4 for a compile error, 5 for an uncaught runtime error, and `n`
for `(exit n)` (`docs/TOOLING.md` §1).

`zig build test --summary all` is the gate: 1319 tests in 170 build
steps, about a minute from a warm cache. `AGENTS.md` lists every build step.

## The language

Each line prints the value after `;; =>` when run with `bin/nexis`
(wrap it in `prn` under `nexis run`):

```clojure
(let [x 5] ((fn [y] (+ x y)) 3))            ;; => 8
(loop [i 0 acc 0]
  (if (< i 10) (recur (+ i 1) (+ acc i)) acc)) ;; => 45, constant stack

(defmacro unless [test & body]
  `(if ~test nil (do ~@body)))
(unless false :got-it)                      ;; => :got-it

(let [{:keys [x y] :or {y 10}} {:x 5}] (+ x y)) ;; => 15
(defn arity ([x] :one) ([x y] :two) ([x y & r] :many))
(arity :a :b :c)                            ;; => :many

(:a {:a 1})                                 ;; => 1, keyword as function
(#{1 2} 2)                                  ;; => 2, set as function
('b {'b 2})                                 ;; => 2, symbol as function
(+ 1 2.5)                                   ;; => 3.5, contagion
(= 1 1.0)                                   ;; => false
(== 1 1.0)                                  ;; => true
(* 1000000000 1000000000)                   ;; => 1000000000000000000, a bignum
(try (/ 1 0) (catch any e e))               ;; => :divide-by-zero

(map inc [1 2 3])                           ;; => (2 3 4), eager
(for [x (range 3) :when (odd? x)] [x (* x x)]) ;; => ([1 1])
(-> {:a 1} (assoc :b 2) (update :a inc))    ;; => {:a 2, :b 2}
(persistent! (reduce conj! (transient []) (range 5))) ;; => [0 1 2 3 4]

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

;; durable refs: values persist across processes (examples/todo-app.nx)
(def conn (db/open "app.edb"))
(def alice (db/ref conn :users :alice))
(with-tx [tx conn] (db/put! tx alice {:age 31}))
@alice                                      ;; => {:age 31}
(db/close conn)
```

An error names its position and shows the source:

```text
$ echo '(when)' > bad.nx && bin/nexis run bad.nx
nexis: bad.nx:1:1: MacroExpansionFailure: when: expected a test
    (when)
    ^^^^^^
```

The namespaces that come with the binary are `nexis.core`
(auto-referred), `db` (durable refs), `nextomic`, `nexis.string`,
`nexis.set`, `nexis.test`, `nexis.pprint`, `nexis.math` and
`nexis.simd` (typed-vector kernels); `clojure.string`, `clojure.set`,
`clojure.test` and `clojure.pprint` are accepted as their names in
`require` (`docs/STDLIB.md` §1). `examples/` holds 24 programs that run
under `zig build examples` (`examples/README.md`).

## Nextomic

Nextomic is a Datomic-class database inside the binary. A fact is a
datom `[e a v t added]`; the store keeps every fact it ever learned; a
db-value is an immutable view at a basis `t`; `as-of`, `since` and
`history` are views of the same indexes; queries and transactions are
data. It is one file on disk, twelve emdb named trees of byte keys
whose order is the index order, with no server and no changes to emdb.

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
                                :patient/allergies [:penicillin]}])]
    (d/transact! c [{:patient/mrn "MRN-1001" :patient/allergies [:latex]}])
    (println (d/q '[:find [?name ...] :where [?p :patient/allergies :latex] [?p :patient/name ?name]]
                  (d/db c)))
    ;; [Mara Quist]
    (println (:patient/allergies (d/entity (d/as-of (d/db c) (:tx intake)) [:patient/mrn "MRN-1001"])))
    ;; #{:penicillin}   (on a fresh store: the chart as of the intake)
    ))
```

`examples/nextomic-app.nx` is the full clinic chart: refs and
component notes, joins with `:in` inputs, predicates and aggregates,
nested and reverse `pull`, `history` and `tx-range`, a speculative
`with`, and a caught `:nextomic/unique`. `test/nextomic/*.nx` are the
executable specification, `query.nx` the fastest tour of the surface.

`docs/NEXTOMIC.md` is the authoritative design: §2 store layout, §3
transactions, §4 db-values and time, §5 the query pipeline, §6 the
Lisp API (§6.1 lazy entities, §6.2 pull patterns), §7 errors, §8
module layout, §10 where Nextomic wins and where it does not, §11 what
it asks of emdb (nothing), §12 its differences from Datomic.

A store file is a sparse 256 MB reservation that grows when it fills:
`ls -l` reports the reservation, `du` the bytes in use.

## Differences from Clojure

The semantics port; the platform does not.

- **No Java interop**: no `(Math/sqrt x)`, `(.method obj)` or
  `import`, and no JVM libraries.
- **No STM, agents or threads**: immutable values, atoms and emdb
  transactions are the concurrency story.
- **Eager sequences**: `map`, `filter` and `for` return lists, and
  `(range)` or `(iterate f x)` need a count.
- **Numbers** are fixnum + bignum and f64: `(= 1 1.0)` is false, and
  an inexact integer `/` is a float, not a ratio.
- **Exceptions are values**: `(catch :tag e ...)` matches a keyword or
  an `{:error :tag}` map; `(catch Exception e ...)` takes everything.

`CLOJURE-REVIEW.md` has the full tables of reader and semantic
differences, and `HANDOFF.md` the known gaps.

## Where things are

| Path | What |
|---|---|
| `AGENTS.md` | Reading order, build steps, rules, layout: start here to contribute |
| `HANDOFF.md` | The state of the tree: how to verify it, the architecture map, what is proven, the known gaps |
| `PLAN.md` | The design decisions (§23), the canonical Form schema (§28) and the Amendment Log |
| `CLOJURE-REVIEW.md` | What nexis takes, adapts and rejects from Clojure, and where it differs |
| `docs/` | One spec per module; `docs/README.md` maps module to spec |
| `ZIG-0.16.0.md` | Zig 0.16 as this tree uses it |
| `src/` | The runtime (one Zig module, `src/root.zig`); `src/stdlib/*.nx` the library written in nexis |
| `test/`, `examples/`, `bench/` | Tests (`test/README.md`), example programs, the benchmark harness |
| `nexis.grammar` | The reader grammar; `src/parser.zig` is generated from it by `zig build parser` (needs `../nexus/bin/nexus`) |

Every store is opened with a 16 KiB page, fixed for the file's life,
so the page size never follows a platform's engine default.

## License

Not yet chosen.
