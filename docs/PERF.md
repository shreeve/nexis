## PERF.md — Measured performance, levers and non-goals

The numbers of record for nexis, each stated once, in §3, with its
host and run in §11. `docs/BENCH.md` owns the method and the harness
(`zig build bench`); this document owns what the harness and the
command line measured, what the numbers say against Clojure's design,
and the levers not yet pulled.

Every scorecard row carries one status:

- `measured` — a §3 row exists, with its provenance in §11.
- `not measured` — implemented, no §3 row.
- `absent` — not in the tree.

A claim that nexis is faster than something, anywhere outside this
file, cites a `measured` row here or is withdrawn (BENCH.md §1).
§3.15 is the one same-machine comparison with Clojure on the JVM: the
same idiomatic programs, run cold and warm, not BENCH.md §5's
`criterium` comparison; anywhere else a Clojure figure is an external
reference and says so.

---

## 1. Axes

| Axis | Question | Metric |
|---|---|---|
| Throughput | cost of a hot operation, warmed up | ns/op, median |
| Latency | request to response, tail included | p99 |
| Memory density | bytes per live value or entry | bytes/N |
| Startup | process exec to first result | ms wall |

A win on one axis is not a win on another. By design nexis expects to
lead Clojure on startup (a native binary against JVM start), on
memory density (a 16-byte value cell with immediates inline, no boxed
numbers) and on durable-state latency (emdb in process); and to trail
it on sustained compute (a bytecode VM against HotSpot's JIT) and on
allocation-heavy throughput (a non-generational collector, no bump
allocation). Only §3 turns any of these into a number.

---

## 2. Scorecard

The Clojure column is its design, not a measurement. "Measured" names
the §3 rows.

| # | Category | Clojure | nexis | Expected | Measured | Status |
|---|---|---|---|---|---|---|
| 1 | Value cell | every value an object reference; `Long`/`Double` boxed | 16-byte `{tag, payload}` cell, not NaN-boxed (`docs/VALUE.md` §1); nil, booleans, chars, fixnums, floats, keywords and symbols inline | smaller | — | not measured |
| 2 | Integer arithmetic | boxed `Long`; `^long` hints, `unchecked-*` | i48 fixnum immediate, promoting to bignum when a result leaves the range; `+ - * / quot mod < <= > >= == abs inc dec` inlined at their arity, `+ - *` at any arity past one (`docs/COMPILER.md` §4.3) | ahead of idiomatic boxed code | §3.1 | measured |
| 3 | Float arithmetic | boxed `Double`; `^double` hints | the f64 bits in the payload word, NaN canonical | ahead of idiomatic boxed code | §3.1 | measured |
| 4 | Persistent map | HAMT | CHAMP (`docs/CHAMP.md`) | faster lookup, less memory | §3.2, §3.4, §3.8 | measured |
| 5 | Persistent set | HAMT | CHAMP | as #4 | §3.2, §3.4, §3.8 | measured |
| 6 | Persistent vector | 32-way trie + tail | 32-way trie + tail; `seq`/`rest`/`next`/`nthrest` an O(1) view | parity | §3.2, §3.4, §3.9 | measured |
| 7 | Persistent list | cons cells | cons cells | parity | §3.2 | measured |
| 8 | Hashing | Murmur3 | xxHash3-64; a heap value's hash cached in its header | faster on long bytes | §3.1 | measured |
| 9 | Keyword identity | interned, identity equality | intern id in the payload, identity equality | parity | §3.1 | measured |
| 10 | Transients | node-owner in-place edit | node-owner in-place edit, the token in an internal node's header (`docs/TRANSIENT.md`) | parity | §3.3 | measured |
| 11 | GC | generational (G1, ZGC) | precise non-moving mark-sweep (`docs/GC.md` §1) | behind under allocation churn | — | not measured |
| 12 | Allocator | TLAB bump pointer | `VM.heap` over size-class slabs with free lists, no per-block prefix (`docs/HEAP.md` §2) | behind on construction | §3.2 | measured |
| 13 | Dispatch | JIT inline caches | threaded code: each handler tail-calls the next through a table indexed by opcode, frameless fast handlers for the hot opcodes over the general ones, routines verified once (`docs/VM.md` §5, §8); no inline caches | behind at warm steady state | §3.8, §3.12, §3.13, §3.19 | measured |
| 14 | Durable state | no stdlib primitive | emdb memory-mapped B+ tree (`docs/DB.md`) | lower latency than an out-of-process store | §3.6 | measured |
| 15 | Serialization | EDN text, Nippy | binary, LEB128 and ZigZag (`docs/CODEC.md`) | smaller, faster than text | §3.5 | measured |
| 16 | Concurrency tax | CAS and STM throughout | single isolate, single writer | none paid, by design | — | by design |
| 17 | SIMD | JIT autovectorization of primitive arrays | `nexis.simd` `sum`, `dot`, `scale` over typed vectors (`docs/TYPED_VECTOR.md`) | ahead on bulk numeric work | — | not measured |
| 18 | Startup | JVM start | native binary, the library loaded from a precompiled image | far ahead | §3.11, §3.15, §3.18 | measured |
| 19 | Compilation | C1/C2 JIT | bytecode, no specialization, no JIT | behind on sustained compute | §3.8 (nexis only), §3.15 | measured |
| 20 | Comptime specialization | JIT inlining, escape analysis | CHAMP hashes an immediate key inline; the rest absent (§6) | — | §3.8 | partly absent |
| 21 | Datalog over datoms | Datomic peer and transactor | Nextomic in process over emdb (`docs/NEXTOMIC.md`) | — | §3.7, §3.11, §3.15 | measured |

---

## 3. Measured rows

Each section states its host, its build and its method; §11 has the run
behind every row. Every row is ReleaseFast. Numbers from different
machines are not comparable (BENCH.md §4). The harness's own rows report
the 30-sample median (BENCH.md §3) unless a section says otherwise.

### 3.1 Scalar

| Row | Median | p5 | p95 | Measures |
|---|---:|---:|---:|---|
| `fixnum_add` | ~1 ns | 0 ns | 1 ns | fixnum add, tag in and out |
| `float_add` | <1 ns* | 0 ns | 0 ns | f64 add |
| `hash_fixnum` | ~1 ns | 1 ns | 1 ns | `dispatch.hashValue` on an immediate |
| `hash_keyword` | 2 ns | 2 ns | 2 ns | `dispatch.hashValue` on a keyword |
| `hash_string_43b` | ~1 ns | 1 ns | 1 ns | the cached hash in the string's header |
| `xxhash3_raw_172b` | 5 ns | 5 ns | 5 ns | xxHash3 over 172 bytes, about 34 GB/s |

\* The median is 0 ns: with volatile operand reads and accumulator
writes the body is little more than one f64 add, below the harness's
resolution. Read it as below resolution, not as free.

### 3.2 Construction

N-fold `conj`/`assoc` from empty with keyword keys; each invocation
builds on a fresh `Heap` and frees it, so memory stays bounded and
N=4096 does not accumulate across repetitions. Apple M5; size-class
slabs, tail claims and inline immediate keys (`docs/HEAP.md` §2,
`docs/VECTOR.md` §2, `docs/CHAMP.md` §6.5). The median of three
invocations' 30-sample medians, the three in brackets. Provenance: §11.

| Row | N | Median |
|---|---:|---:|
| `list_cons_n` | 16 | 130 ns [128–130] |
| `list_cons_n` | 256 | 1.44 μs [1.40–1.44] |
| `list_cons_n` | 4096 | 21.2 μs [20.9–21.4] |
| `vector_conj_n` | 16 | 212 ns [211–213] |
| `vector_conj_n` | 256 | 2.31 μs [2.31–2.34] |
| `vector_conj_n` | 4096 | 36.5 μs [36.1–36.9] |
| `map_assoc_n` | 16 | 710 ns [709–710] |
| `map_assoc_n` | 256 | 15.3 μs [15.3–15.3] |
| `map_assoc_n` | 4096 | 406 μs [388–408] |
| `set_conj_n` | 16 | 654 ns [651–659] |
| `set_conj_n` | 256 | 12.8 μs [12.8–12.8] |
| `set_conj_n` | 4096 | 340 μs [332–770] |

The smaller the per-operation work, the more of it is the allocator:
list cons gains most from the slabs, vector conj also from claiming
its tail's next slot instead of copying the tail, map assoc (hash,
path copy, trie walk) least. A fresh heap takes its first slabs from
those an ended heap left (`docs/HEAP.md` §2); without that pool the
N=16 rows measure mapping them. An external reference puts Clojure's
`assoc` on a 4k-entry `PersistentHashMap` at 100–300 ns after JIT
warm-up; not a same-machine comparison.

### 3.3 Transient construction

The same builds through `transient`, the `!` operations and
`persistent!`, measured as §3.2. A transient edits the nodes it owns
in place (`docs/TRANSIENT.md` §1).

| Row | N | Median |
|---|---:|---:|
| `transient_vector_conjbang_n` | 16 | 140 ns [139–172] |
| `transient_vector_conjbang_n` | 256 | 730 ns [729–732] |
| `transient_vector_conjbang_n` | 4096 | 9.90 μs [9.66–11.7] |
| `transient_map_assocbang_n` | 16 | 496 ns [492–549] |
| `transient_map_assocbang_n` | 256 | 7.25 μs [7.21–7.86] |
| `transient_map_assocbang_n` | 4096 | 156 μs [144–173] |
| `transient_set_conjbang_n` | 16 | 473 ns [468–475] |
| `transient_set_conjbang_n` | 256 | 6.71 μs [6.69–7.72] |
| `transient_set_conjbang_n` | 4096 | 127 μs [127–152] |

### 3.4 Lookup

A prebuilt collection; N lookups, sequential for the vector and by
present key for the map and set.

| Row | N=256 | N=4096 |
|---|---:|---:|
| `vector_nth_n_sequential` | 136 ns | 2.94 μs |
| `map_get_n_hit` | 2.62 μs | 63.6 μs |
| `set_contains_n_hit` | 1.99 μs | 38.5 μs |

Sequential `nth` within dense leaves is cache-hot and near the
harness's resolution per operation; a cold-cache random-access row
does not exist. External references put Clojure's 4k-entry
`PersistentHashMap` get at 25–40 ns and `nth` at 2–4 ns after JIT
warm-up; not same-machine comparisons. §3.8 has the map and set rows
with an immediate key hashed inline.

### 3.5 Codec

Apple M5, measured as §3.2.

| Row | Median |
|---|---:|
| `codec_encode_fixnum` | 21 ns [21–25] |
| `codec_decode_fixnum` | 8 ns [8–8] |
| `codec_encode_map_n64` | 686 ns [685–747] |
| `codec_decode_map_n64` | 4.62 μs [4.53–4.62] |

Encoding writes into a presized buffer and does not allocate values;
decoding builds them, which is the only row the slabs move.

### 3.6 Durable refs (`db/*`)

| Row | Apple M1 | Apple M5 | Measures |
|---|---:|---:|---|
| `db_put_commit_scalar`, `NEXIS_DURABILITY=commit` | — | 330 ns | one put and a commit that syncs nothing (`docs/DB.md` §3.3) |
| `db_put_commit_scalar` | 6.15 ms | 6.00 ms | one put and a commit in the default durability, `:durable`: two `F_FULLFSYNC`, per commit, not per put |
| `db_get_hit_scalar` | 1.04 μs | 60 ns | read transaction, B+ tree lookup, decode of a fixnum, abort |

The two `db_get_hit_scalar` figures differ by 17×; the difference is
unexplained and the row needs a rerun on one machine with the emdb
revision recorded. A batch of puts in one transaction pays the commit
once.

### 3.7 Nextomic — query and pull over 200k datoms

`bench/nextomic.zig` builds both stores (emdb, 16 KiB pages) and runs
every row through the engine's Zig API: 40,000 employees in 20
departments, five attributes each (~200k datoms), then, after those
rows have run, two chains in the same store (10 and 20,000 entities
linked by a ref). The integration tests carry 10k-datom twins that
check the row counts (`test/integration/nextomic_q.zig`,
`nextomic_pull.zig`). Each figure is the best of five invocations, the
spread across them in brackets.

| Harness row | What | Median |
|---|---|---:|
| `q_join3_by_dept_2k_rows` | 3-way join by department (`avet` seek → `vaet` → `eavt`), 2000 rows | 0.94 ms [0.94–1.05] |
| `q_join3_by_age` | 3-way join by age (`avet` range → `eavt` → `eavt`), 851 rows | 1.78 ms [1.78–2.06] |
| `q_count_hash_join` | `(count ?e)` by department (`aevt` scan, hash join), 667 rows | 0.33 ms [0.33–0.39] |
| `q_join3_from_1_age` | 3-way join from one age, nested loop, 851 rows | 0.32 ms [0.32–0.72] |
| `q_join3_from_3_ages` | from three ages, nested loop, 2602 rows | 1.02 ms [1.02–2.87] |
| `q_join3_from_7_ages` | from seven ages, hash join on name and salary, 6259 rows | 2.57 ms [2.57–6.04] |
| `q_chain_1000_clauses` | 1000-clause chain over a 10-entity chain, no row survives: planning | 3.3 ms [3.3–4.5] |
| `q_chain_100_over_20k` | 100-clause chain over a 20k-entity chain, finding its ends, 19,900 rows | 34.8 ms [34.8–36.4] |
| `q_chain_100_find_all_over_20k` | the same chain finding all 101 variables | 72.2 ms [72.2–75.6] |
| `pull_many_star` | `pull-many [*]` over 20,000 entities, one read transaction | 9.95 ms [9.95–10.3] |
| `pull_many_nested_ref_limit` | `pull-many` with a nested ref and `:limit`, 20,000 entities | 15.5 ms [15.5–15.7] |
| `pull_reverse_ref_2k` | reverse-ref pull of one department's 2,000 employees | 0.095 ms [0.095–0.096] |

Through `bin/nexis` over a chain of 100,000 entities, one query at a
time: a 300-clause chain finding its two ends takes 0.67 s, finding
all 301 variables 1.5 s; a 1000-clause chain over a 10-entity chain
takes 3.0 ms. The planner keeps its estimates until a clause's
variables change, drops dead variables and parks output-only ones,
gathers joins column by column from the smaller side's index, and
keeps a constant-prefix scan and its indexes for the query
(`docs/NEXTOMIC.md` §5); a profile of the chain puts the time in the
hash probe of the join (`Relation.join`, `Cell.hash`) and nothing in
the planner.

A profile of the three-way join rows (`sample` on the ReleaseFast
test binary) puts about 30 % of the time in emdb's page search
(`page.searchPage`, `simd.compare`), 10 % in `Exec.scanInto` and about
5 % in decoding string values out of keys; the rest is relation
building and the arena. Debug builds under the testing allocator are
an order of magnitude slower and are not measurements.

### 3.8 Dispatch and lookup, Apple M5

Rows for two changes: `vm` (the hot groups resolve operands through
the fetched frame; the collection check follows only an instruction
that could allocate, `docs/VM.md` §8, §9) and `champ` (an immediate
key hashes inline, `docs/CHAMP.md` §5.1). Best of five invocations of
the 30-sample median, spread in brackets. The `vm` rows run a routine
compiled once on one VM, so a sample is the dispatch loop alone,
10,000 iterations. §3.12 and §3.19 have the `vm` rows on later code.

| Row | Median | Change |
|---|---:|---|
| `vm_loop_10k` | 265.12 μs [265.1–288.6] | `vm` |
| `vm_global_call_10k` (`(inc1 i)` through a Var) | 469.73 μs [469.7–497.0] | `vm` |
| `vm_keyword_get_10k` (`(:k m)`, 12-entry map) | 517.11 μs [517.1–536.1] | `vm` |
| `eval_simple_loop` (compile and run a 100-iteration loop) | 5.06 μs [5.06–5.40] | `vm` |
| `map_get_n_hit` N=256 | 2.10 μs [2.10–2.17] | `champ` |
| `map_get_n_hit` N=4096 | 54.32 μs [54.3–54.9] | `champ`; 13.3 ns per get |
| `set_contains_n_hit` N=256 | 1.19 μs [1.19–1.23] | `champ` |
| `set_contains_n_hit` N=4096 | 28.17 μs [28.2–28.3] | `champ`; 6.9 ns per contains |

A Var load is one read of the routine's `var_table` entry and the
Var's root (`docs/VM.md` §10.7).

### 3.9 Vector traversal through `bin/nexis`

Wall time of `bin/nexis run` (ReleaseFast). `seq`, `rest`, `next` and
`nthrest` of a vector are an O(1) view, a list subkind over the vector
(`docs/LIST.md`), not a copy.

| Program | Time |
|---|---:|
| `(loop [v (vec (range 20000))] (if (seq v) (recur (pop v)) v))` | 0.11 s |
| 100 × `(reduce + (rest v))`, `v` of 100,000 elements | 0.14 s |

### 3.10 Common forms through `bin/nexis`

What the compiler emits for common forms (instruction counts,
`docs/COMPILER.md` §4.8) and what that costs at run time: `let`
aliases, forms for effect, returns in a function's tail, branching on
`and`, `or` and `not`, `is` as one helper call, `case` through one
lookup, overload dispatch on inlined compares, `assert` built at
expansion. Wall time inside one `bin/nexis run` of a probe program,
read with `nano-time` around each loop; the median of nine runs, range
in brackets.

| Loop | Median |
|---|---:|
| 200k calls of a 10-keyword `case` with a default | 27.6 ms [27.1–29.0] |
| 200k calls of a 10-int `case` with a default | 24.6 ms [24.3–26.2] |
| 200k calls `(multi 1 2)` of a three-arity `defn` | 32.4 ms [31.8–34.0] |
| 200k calls of a fn nesting `when-let` and `if-let` | 10.2 ms [9.9–10.8] |
| 200k `(assert (pos? 1) "positive")` | 5.7 ms [5.3–5.8] |
| 200k calls destructuring a vector and a map | 32.9 ms [32.1–35.0] |
| 3 × `(count (for [x (range 100000)] (inc x)))` | 45.3 ms [44.6–46.6] |
| 60k `is` assertions (`=`, a predicate, `thrown?`) through `run-tests` | 22.3 ms [21.8–23.3] |

An assertion is one call of a `nexis.test` helper (7 instructions for
`(is (= ...))`), not its whole report inlined (17).

---

### 3.11 Against babashka and Datalevin

The same workloads through nexis and babashka, and through Nextomic and
Datalevin, by `bench/compare/run.clj` (`docs/BENCH.md` §12): ten
rounds, the implementations alternating, the median of the time
measured inside each process with its minimum and 95th percentile.
Every workload gave the same answers in every run of both systems. A
ratio above 1 means nexis is slower. Provenance: §11.

| Workload | nexis | babashka 1.13 | ratio | nexis RSS | bb RSS |
|---|---:|---:|---:|---:|---:|
| startup (`-e`) | 5.33 ms | 13.0 ms | 0.41 | 6 MB | 30 MB |
| loop/recur, 1M | 15.0 ms | 64.5 ms | 0.23 | 6 MB | 83 MB |
| sort, 1M ints | 89.7 ms | 226 ms | 0.40 | 157 MB | 114 MB |
| `frequencies` and `group-by`, 1M | 90.9 ms | 206 ms | 0.44 | 57 MB | 130 MB |
| fib 30 | 53.0 ms | 118 ms | 0.45 | 6 MB | 77 MB |
| map through transients, 1M | 351 ms | 720 ms | 0.49 | 122 MB | 178 MB |
| destructuring loop | 205 ms | 331 ms | 0.62 | 24 MB | 84 MB |
| map build and read, 1M | 623 ms | 972 ms | 0.64 | 140 MB | 193 MB |
| vector conj and nth, 1M | 55.6 ms | 81.4 ms | 0.68 | 65 MB | 127 MB |
| string build and split, 1 MB | 13.2 ms | 18.5 ms | 0.71 | 32 MB | 72 MB |
| map/filter/reduce over 1M maps | 36.8 ms | 48.5 ms | 0.76 | 195 MB | 212 MB |

| Phase (100k entities × 5 attributes) | Nextomic | Datalevin 1.1 | ratio |
|---|---:|---:|---:|
| open an existing store | 121 μs | 13.4 ms | 0.01 |
| create a store | 515 μs | 19.8 ms | 0.03 |
| load, default commit | 394 ms | 2.32 s | 0.17 |
| load, no per-commit flush | 451 ms | 2.17 s | 0.21 |
| 10k point lookups by a unique attribute | 11.1 ms | 34.0 ms | 0.33 |
| three-clause join, 20 × 1,000 rows | 11.4 ms | 35.6 ms | 0.32 |
| aggregate query | 18.9 ms | 109 ms | 0.17 |
| pull of 10k entities with a nested ref | 8.01 ms | 74.3 ms | 0.11 |
| 1,000 one-datom transactions, default commit | 16.8 ms | 169 ms | 0.10 |
| 1,000 one-datom transactions, no per-commit flush | 27.3 ms | 64.4 ms | 0.42 |
| as-of and history query | 1.89 ms | no counterpart | — |
| store after the load (allocated) | 51 MB | 46 MB | 1.1 |

What the rows say:

- nexis is ahead of babashka on every row: 2–4× on loops, calls
  (`fib`), `sort`, transient maps and `frequencies`/`group-by`,
  1.3–1.6× on destructuring, the map build, vector `conj`/`nth`,
  string splitting and the `map`/`filter`/`reduce` pipeline. It starts
  in about 5 ms with a 6 MB resident set.
- Sequences are lazy and chunked, as babashka's (`docs/BENCH.md`
  §12). Against an eager build of the pipeline, the timed phase retires
  4.1% more instructions (949 M against 912 M) and takes 16% longer
  (41.8 against 36.2 ms), with a resident set 2.5% smaller (189 against
  194 MB). Each stage caches the chunks it realizes: 94,000 chunk steps
  of two blocks each, and the phase grows the resident set by 36 MB
  where eager vectors grew it by 25 MB; no cycle runs in the phase, so
  every block is fresh memory. Fusing the stages into the `reduce`
  would avoid the chunks, but runs a function again when the same seq
  is also held and walked elsewhere, where Clojure caches, so nexis
  does not.
- `frequencies` and `group-by` peak at 60 MB against an eager build's
  40 MB: the lazy `map` that `frequencies` counts stays reachable from
  the call's argument while the phase's one cycle runs (TODO.md #13).
- Startup retires 48.4 M instructions against 37.6 M for an eager
  build's library (6.7 against 5.9 ms): the embedded library is 66 KB
  against 44 KB, at about 0.5 M instructions a KB.
- Its resident set is below babashka's on every row but `sort`, whose
  buffers outside the heap take about 80 MB in this build; §3.34 takes
  them to 24 MB and the program's peak to 80 MB.
- Nextomic is ahead of Datalevin on every phase: creating, opening,
  loading, lookups, joins, aggregates, pull and small transactions.
- The default-commit rows compare different guarantees. Nextomic's
  connect `{:durability :commit}` (`docs/DB.md` §3.3) syncs nothing: a
  commit is atomic and survives a crash of the process, and the file is
  synced once at `release` and at the end of the program, outside the
  timed phase. Datalevin's calls `fsync`, which on macOS does not empty
  the drive's cache (`docs/BENCH.md` §12). A Nextomic connection opened
  `{:durability :durable}` syncs each commit, two `F_FULLFSYNC`, and
  pays 3.42 s for the 1,000 transactions. The no-flush rows include one
  sync at the end in both systems.
- The store is 51 MB against Datalevin's 46 MB, which keeps no history
  (1.1×; `du` of the store `nexis-load.nx` builds). §3.36 measures it
  tree by tree, and the cost of each lever.
- A map built persistently still marks its whole live set at every
  cycle (§6, the collector's trigger). A native calling a native needs
  a safe point in `callValue` (`docs/GC.md` §7): without it `reduce`
  kept the garbage of a million persistent `conj`s resident until it
  returned.

### 3.12 Threaded dispatch and direct calls, Apple M5

The rows of §3.8 after threaded dispatch, the hot handlers and the
direct call paths (`docs/VM.md` §6, §8). Five invocations of `zig
build bench --filter vm,compiler`, the best 30-sample median with the
spread of the five. Provenance: §11.

| Row | Median |
|---|---:|
| `vm_loop_10k` | 53.03 μs [53.0–60.7] |
| `vm_global_call_10k` (`(inc1 i)` through a Var) | 133.23 μs [133.2–148.6] |
| `vm_keyword_get_10k` (`(:k m)`, 12-entry map) | 229.28 μs [229.3–252.1] |
| `eval_simple_loop` (compile and run a 100-iteration loop) | 2.12 μs [2.12–2.41] |

The counting loop is 4 instructions per iteration, `cmp:lt`,
`jump:if-false`, `math:add` and `jump:jmp`, and 3 dispatches, the
comparison running its branch (`docs/VM.md` §8): 5.3 ns per
iteration. The `(inc1 i)` loop, 6 instructions and the callee's 2,
runs 13.3 ns per iteration. The destructuring loop calls `get`, `nth`,
`nthnext` and `count` as natives; a native call costs a
`var:load-var`, the moves into its block and one `call:call`.

### 3.13 Calls from natives, Apple M5

What a sequence native pays per element (`docs/VM.md` §6 "Repeated
calls", §8, §10.3; `docs/LIST.md` §1): a keyword or symbol callee looks
itself up in place in `call:call`; `map`, `filter`, `remove`, `keep`
and `reduce` prepare their callback once (`vm.Callback`); a vector or
a list is stepped, and a root pushed, inline in the native's loop; `+`
of two fixnums, `inc`, `dec`, `even?` and `odd?` of one compute inline.
Provenance: §11.

The pipeline's timed phase in instructions retired (`/usr/bin/time
-l`, each stage's program minus the one before it, median of five). No
collection runs in the phase: the setup's last cycle leaves 134 MB
live, and the phase allocates less than that before the next is due.

| Stage | Instructions |
|---|---:|
| `(filter (fn [row] (even? (:group row))))`, 1M rows | 683 M |
| `(map :score)`, 500k rows | 94 M |
| `(map inc)`, 500k | 64 M |
| `(reduce +)`, 500k | 57 M |
| the timed phase | 898 M |

The harness's `vm` rows are unchanged by it (`vm_keyword_get_10k`
172.77 μs [172.8–199.7]). What is left of the pipeline's phase is the
closure body's six dispatches per row (`var:load-var`,
`mov:load-const`, `mov:move`, two `call:call`, `call:return`; about a
third of the samples in a `sample` profile), the loop's entry and exit
for each callback, and the first touch of each row's map (`mapGet`,
about an eighth).

### 3.14 The heap of the sequence natives, Apple M5

Where the pipeline's memory goes: the setup runs four cycles, at 16,
34, 67 and 134 MB live, in 0.4, 2.2, 4.4–6.8 and 12.5–15.5 ms; only
the first frees anything (358 blocks), and the timed phase allocates 25
MB, less than the 134 MB the next cycle waits for, so no cycle runs in
it. The rows' maps (1M maps of 128 bytes), the rows' vector and the
phase's three result vectors are the heap; the root stack keeps no
capacity a `mapv` grew it to, the collector's gray worklist is trimmed
after a cycle, and the malloc'd buffers `range`'s list and the two
growth steps used are returned (§6 "Levers pulled"). Instructions
retired (`/usr/bin/time -l`, median of five, the phase as the whole
program minus its setup alone) and peak resident set:

| Pipeline program | Value |
|---|---:|
| setup (`mapv` over `range`), instructions | 1,984 M |
| timed phase, instructions | 884 M |
| setup alone, peak RSS | 170 MB |
| whole program, peak RSS | 195 MB |

Every language workload of §3.11 holds 35–43 MB less than before the
trim, and the pipeline's resident set is under babashka's. `sort`
holds 80 MB of buffers beside its input for a million, which §3.34
takes to 24 MB.

The trigger (`docs/GC.md` §7), set by hand, five runs each of the
pipeline program, cycles and the phase's time:

| Growth, floor | Cycles | Phase | Peak RSS |
|---|---:|---:|---:|
| 100 %, 16 MiB (the default) | 4 | 34.1–35.0 ms | 194 MB |
| 200 %, 16 MiB | 3 | 34.3–35.6 ms | 194 MB |
| 100 %, 64 MiB | 2 | 36.6–38.8 ms | 194 MB |
| 50 %, 16 MiB | 6 | 46.1–53.9 ms | 186 MB |
| 25 %, 16 MiB | 8 | 41.9–45.3 ms | 178 MB |
| 10 %, 16 MiB | 11 | 56.6–60.9 ms | 178 MB |

A lower growth brings a cycle, a mark of the 150 MB live, into the
timed phase and saves at most 16 MB; a higher growth or floor saves
setup cycles the benchmark does not time and holds the same memory.

### 3.15 Linux x86_64: nexis against babashka and JVM Clojure, Nextomic against Datalevin and Datomic

The workloads of §3.11 on an Intel Core Ultra 9 185H under Linux, with
two more columns on each side: Clojure 1.12.6 on HotSpot (JDK 21) for
the language, and Datomic Local 1.0.291 and Datomic Pro 1.0.7705
(dev transactor) for the database, by `bench/compare/run.clj --n 10
--max-load 4 --pin 0-11` (`docs/BENCH.md` §12): ten rounds, the
implementations alternating, every process pinned to the six
performance cores' twelve threads, the frequency governor left at
`powersave`. The run is seven pieces of a few minutes each, four of
language workloads (nexis, babashka and Clojure in each) and three of
the database (Nextomic beside one other system in each), so babashka
and Nextomic are each piece's control. Every workload gave the same
answers in every run of every system. Cells are the median of the
time measured inside each process; a ratio above 1 means nexis is
slower. Provenance: §11.

**Language.** Clojure cold is the program's one run in a fresh JVM, as
babashka and nexis run it; Clojure warm is the median of ten runs in
one JVM after twenty discarded ones. The wall columns are the whole
process, start to exit, of the one-shot runs; RSS is its peak.

| Workload | nexis | babashka 1.13 | Clojure cold | Clojure warm | ÷ bb | ÷ cold | ÷ warm | wall: nexis / bb / Clojure | RSS: nexis / bb / Clojure |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| startup (`-e`) | 4.72 ms | 7.79 ms | 333 ms | — | 0.61 | 0.01 | — | (the cells) | 5 / 32 / 108 MB |
| loop/recur, 1M | 10.5 ms | 92.6 ms | 22.5 ms | 14.8 ms | 0.11 | 0.46 | 0.71 | 18 ms / 109 ms / 451 ms | 5 / 85 / 135 MB |
| sort, 1M ints | 193 ms | 333 ms | 202 ms | 147 ms | 0.58 | 0.95 | 1.31 | 234 ms / 447 ms / 664 ms | 119 / 116 / 249 MB |
| `frequencies` and `group-by`, 1M | 98.0 ms | 248 ms | 167 ms | 106 ms | 0.40 | 0.59 | 0.92 | 138 ms / 362 ms / 635 ms | 42 / 133 / 267 MB |
| fib 30 | 28.2 ms | 162 ms | 13.8 ms | 4.68 ms | 0.17 | 2.04 | 6.02 | 35 ms / 179 ms / 441 ms | 5 / 79 / 113 MB |
| map through transients, 1M | 433 ms | 1.03 s | 460 ms | 354 ms | 0.42 | 0.94 | 1.23 | 446 ms / 1.05 s / 899 ms | 86 / 181 / 306 MB |
| destructuring loop | 211 ms | 436 ms | 118 ms | 38.3 ms | 0.49 | 1.80 | 5.53 | 222 ms / 451 ms / 567 ms | 23 / 86 / 337 MB |
| map build and read, 1M | 936 ms | 1.42 s | 605 ms | 452 ms | 0.66 | 1.55 | 2.07 | 950 ms / 1.44 s / 1.06 s | 97 / 195 / 573 MB |
| vector conj and nth, 1M | 78.0 ms | 123 ms | 69.2 ms | 30.3 ms | 0.63 | 1.13 | 2.58 | 88 ms / 143 ms / 516 ms | 35 / 128 / 260 MB |
| string build and split, 1 MB | 29.9 ms | 30.0 ms | 61.0 ms | 12.5 ms | 1.00 | 0.49 | 2.39 | 38 ms / 45 ms / 503 ms | 30 / 74 / 136 MB |
| map/filter/reduce over 1M maps | 59.8 ms | 46.0 ms | 47.2 ms | 22.4 ms | 1.30 | 1.27 | 2.67 | 226 ms / 570 ms / 566 ms | 188 / 214 / 347 MB |

What the language rows say:

- Warm, HotSpot is faster than nexis on eight of the ten programs:
  1.2–1.3× on the transient map and `sort`, 2.1–2.7× on the map
  build, string splitting, vectors and the pipeline, 5.5× on the
  destructuring loop and 6.0× on `fib`, where a compiled call is a
  few nanoseconds and a nexis call is an interpreted frame. nexis is
  ahead on the counting loop (0.71) and on `frequencies`/`group-by`
  (0.92), which it runs as Zig natives.
- Cold, in a fresh JVM, Clojure is faster inside the timed body on
  five of ten (1.1–2.0×: vectors, the pipeline, the map build, the
  destructuring loop, `fib`) and slower on the other five. Counting
  the whole process, the JVM's start of about 0.33 s puts nexis ahead
  on every one-shot program.
- nexis starts in 4.7 ms, 0.61 of babashka's time and 70× faster than
  `clojure -M` (the CLI's launcher included), and its resident set is
  below the JVM's on every row, 1.8–27× smaller.
- Against babashka nexis is ahead on startup and eight of the ten
  programs (0.11–0.66), level on string splitting (1.00) and behind on
  the `map`/`filter`/`reduce` pipeline (1.30), whose `filter` calls a
  closure from a native once for each of the million rows
  (`vm.VM.callPrepared` is the largest share of the process's
  cycles).
- `sort` spends half its cycles in `mergeSort`, three quarters of
  those at one load: Zig 0.17's x86-64 code writes the comparison's
  `VmError!Order` result to the stack as a 16-bit and an 8-bit store
  and reads it back as one 32-bit load, which the store buffer cannot
  forward. Built by Zig 0.16 at `95791b0`, the program runs the phase
  in 144 ms; built at `1489ef9`, which moves the tree to Zig 0.17 and
  leaves the sort code as it is, in 181 ms, the process retiring 1.4%
  fewer instructions in 21% more cycles. §3.32 compares the keys in
  registers: 93–96 ms on this host; §3.34 sorts the values alone,
  through a scratch array of half of them: 54–56 ms.

**Database.** 100 departments and 100,000 people with five attributes.
The durability of each row (`docs/BENCH.md` §12, traced with `strace`):
Nextomic's default-commit rows connect `{:durability :commit}`, which
syncs nothing and survives a crash of the process; its durable
connection, nexis's default, issues two `fdatasync` per commit.
Datalevin's default commit is durable (one `fdatasync` and an
`O_DSYNC` meta write). Datomic Local's one mode is durable (two
`fdatasync`). Datomic Pro's dev transactor acknowledges without a sync
(H2 writes the file in batches), so its commit is closest to
Nextomic's default and weaker: an unwritten batch can be lost with the
transactor. The Nextomic column is its run beside Datalevin; its runs
beside the two Datomics agree within 5% on every phase but `create`
(5.95, 9.89 and 10.0 ms), and each ratio is taken within its own run.

| Phase | Nextomic | Datalevin 1.1 | Datomic Local | Datomic Pro | ÷ Datalevin | ÷ Local | ÷ Pro |
|---|---:|---:|---:|---:|---:|---:|---:|
| create a store | 5.95 ms | 81.4 ms | 140 ms | 1.00 s | 0.07 | 0.07 | 0.01 |
| load, default commit | 506 ms | 3.63 s (durable) | 9.79 s (durable) | 4.84 s | 0.14 | 0.05 | 0.10 |
| load, every commit durable | 1.33 s | 3.63 s | 9.79 s | — | 0.37 | 0.14 | — |
| index after the load | (in the load) | (in the load) | — | 2.91 s | | | |
| open an existing store | 288 μs | 9.99 ms | 35.2 ms | 727 ms | 0.03 | 0.01 | 0.00 |
| 10k point lookups by a unique attribute | 17.4 ms | 58.4 ms | 261 ms | 249 ms | 0.30 | 0.06 | 0.07 |
| the same, warm (median of nine passes) | 11.9 ms | 46.6 ms | 141 ms | 12.3 ms | 0.25 | 0.08 | 0.97 |
| three-clause join, 20 × 1,000 rows | 22.2 ms | 56.8 ms | 225 ms | 131 ms | 0.39 | 0.09 | 0.16 |
| aggregate query | 35.1 ms | 132 ms | 864 ms | 349 ms | 0.27 | 0.04 | 0.10 |
| pull of 10k entities with a nested ref | 12.5 ms | 135 ms | 301 ms | 75.0 ms | 0.09 | 0.04 | 0.17 |
| the same, warm (median of nine passes) | 11.3 ms | 112 ms | 261 ms | 16.2 ms | 0.10 | 0.04 | 0.71 |
| 1,000 one-datom transactions, default commit | 18.4 ms | 1.98 s (durable) | 5.52 s (durable) | 2.48 s | 0.01 | 0.00 | 0.01 |
| 1,000 one-datom transactions, every commit durable | 2.25 s | 2.01 s | 5.45 s | — | 1.12 | 0.41 | — |
| 1,000 one-datom transactions, no per-commit flush | 20.4 ms | 68.8 ms | — | — | 0.30 | — | — |
| 1,000 one-entity transactions, default commit | 29.1 ms | 2.10 s (durable) | 5.61 s (durable) | 859 ms | 0.01 | 0.01 | 0.03 |
| 1,000 upserts of one entity, default commit | 15.3 ms | 2.05 s (durable) | 5.50 s (durable) | 736 ms | 0.01 | 0.00 | 0.02 |
| as-of and history query | 3.73 ms | no counterpart | 35.6 ms | 23.9 ms | — | 0.10 | 0.15 |
| store after the load (allocated) | 52 MB | 42 MB | 25 MB | 18 MB | 1.24 | 2.1 | 2.9 |
| peak RSS, query process | 145 MB | 672 MB | 1127 MB | 698 MB + 1117 MB transactor | | | |

Datalevin's and Datomic Local's load and default-commit rows are
already durable, so the durable load row repeats their figure; the
second and third write batches of the Datomic twins run untimed where
no mode matches.

What the database rows say:

- Nextomic is ahead of Datalevin, Datomic Local and Datomic Pro on
  every phase timed cold but Datalevin's durable commit: 2.6–11× on
  lookups, joins, aggregates and pull against Datalevin, 6–25× on
  those and the time views against the two Datomics, and 14× or more
  on creating and opening a store; its load is 9.6× faster than
  Datomic Pro's (before Datomic's indexing) and, durable against
  durable, 7.3× faster than Datomic Local's; small default-commit
  transactions are 30–136× faster than Datomic Pro's, whose
  transactor round trip (0.7–2.5 ms a transaction, no sync) is the
  cost an in-process commit does not pay.
- Warm, Datomic Pro's peer is level with Nextomic at point lookups
  (12.3 ms against 11.9 ms, 0.97, within the spread) and behind on
  pull (0.71): once the JIT has compiled the peer and its object
  cache holds the segments, a lookup is a lookup in memory. Its cold
  figures are 20× and 4.6× those, which is what a peer that just
  started pays. Datomic Local's client API stays 12–23× behind even
  warm.
- Durable against durable, Nextomic's commit (two `fdatasync`,
  2.25 ms) is 12% slower than Datalevin's (one `fdatasync` and an
  `O_DSYNC` write, 2.01 ms) and 2.4× faster than Datomic Local's
  (5.45 ms). The flushes are not the difference: the smallest emdb
  commit nexis makes takes 1.82 ms, level with LMDB's. A one-datom
  Nextomic transaction writes 14 pages of 16 KiB, half of them the
  transaction entity and the history Datalevin does not keep, where
  Datalevin's writes 13 of 4 KiB (§3 "Durable commits"). A durable
  load of 100,000 entities takes 1.33 s, against 3.63 s and 9.79 s.
- `create` is a new file: emdb syncs the file's first pages and its
  directory when it creates the file (two `fdatasync` and an `fsync`
  of the directory, `strace -T`), most of the phase's 6 ms.
- The store is 52 MB (§3.36's run on this host; the other rows of
  the Nextomic column are this section's run, whose store was 137 MB)
  against Datomic Pro's 18 MB and Datomic Local's 25 MB, which keep
  history too (2.9× and 2.1×), and Datalevin's 42 MB without history
  (1.24×). Datomic Local's `index-eavt` file holds the load in 4.0 MB,
  about 8 bytes a datom; Nextomic's EAVT holds 14.7 bytes of key and
  value a datom plus emdb's 10, and its history trees nothing until a
  fact is retracted (§3.36). Datomic's remaining lead is its
  block-compressed segments (§6 "Store size").
- Datomic Pro's load returns before it has indexed: the transactor
  folds the log into its indexes in the background, 2.91 s more for
  this load, which Nextomic's 506 ms already includes.
- Memory: Nextomic's query process peaks at 145 MB; Datomic Pro's
  peer at 698 MB beside a 1.1 GB transactor (the distribution's
  `-Xms1g -Xmx1g`), Datomic Local at 1.1 GB, all at the JDK's default
  heap sizing.

### 3.16 Loop shape, Apple M5

What the compiler's loop shape (`docs/COMPILER.md` §5.6, §5.7) saves:
a `recur` computes its arguments in an order that needs no temporary
when one that cannot fail may wait, and repeats the loop's test at its
bottom instead of jumping back to it. Provenance: §11.

Per unit, by `tools/speed/harness.py` over the micro programs at two
sizes (5 M and 10 M iterations; `fib` 27 and 30), seven interleaved
rounds: the median of the paired differences, the range in brackets.

| Program | Dispatches | Instructions | Cycles |
|---|---:|---:|---:|
| `count`, `(recur (inc i))` | 2 | 195.0 [194.3–195.3] | 20.1 [19.0–27.9] |
| `acc`, `(recur (inc i) (+ acc i))` | 3 | 281.0 [280.7–281.3] | 32.5 [21.3–46.8] |
| `lc`, `(recur (inc i) 7)` | 3 | 240.0 [239.7–240.2] | 27.7 [21.2–31.5] |
| `gcall`, `(recur (inc i) (f 7))` | | 481.1 [480.3–481.2] | 59.5 [50.7–66.1] |
| `fib`, per call (no loop) | | 488.6 [488.4–489.3] | 80.0 [75.7–93.5] |

Whole process of the `bench/compare` programs under `/usr/bin/time -l`:
loop/recur 516.2 M instructions, the destructuring loop 6,044 M. The
other language workloads are unchanged by the loop shape (`fib`'s
bytecode is the same; its cycles move with the handlers' addresses).

### 3.17 Arithmetic past two arguments, Apple M5

`+`, `*` and `-` past two arguments lower to a left fold of `math`
instructions over the arguments' values (`docs/COMPILER.md` §4.3)
instead of a call of the native through its Var. Provenance: §11.

| Measure | Value |
|---|---:|
| `(recur (inc i) (+ acc i 1 2))`, instructions an iteration (7 rounds, 5 M/10 M) | 455.1 [455.0–455.1] |
| the same, cycles an iteration | 51.3 [46.3–57.4] |
| destructuring loop, whole process (5 rounds) | 5,755 M instructions |
| destructuring loop, its timed phase (9 interleaved rounds) | 229.9 ms [226.2–236.4] |

The destructuring loop's `(+ a b x y (count more))` is four
`math:add`, where a native call was a `var:load-var`, four moves and a
five-argument call.

### 3.18 The stdlib image, Apple M5

Startup with the library booted from its precompiled image instead of
its sources (`docs/STDLIB.md` §1): 21 interleaved rounds of each
command under `/usr/bin/time -l`; medians, the instruction range in
brackets. Provenance: §11.

| Command | Instructions | Cycles | Wall | Resident set |
|---|---:|---:|---:|---:|
| `-e nil` | 21.44 M [21.34–25.24] | 6.57 M | 4.07 ms | 3.62 MB |
| `-e '(+ 1 2)'` | 21.48 M [21.39–21.81] | 6.49 M | 3.85 ms | 3.74 MB |

Booting the sources instead retires 48.5 M instructions (5.9 ms, 6.0
MB).

- Loading the image (192 KB: 352 routines, 6,276 instructions, 1,524
  heap values, 502 names) retires about 2.5 M instructions: the names
  0.74 M, the namespaces and Vars 0.29 M, the heap values 0.92 M, the
  routines 0.54 M. Booting the sources retired 29.4 M, about 0.45 M a
  KB of `.nx`; with the image, library code costs its loading, not
  its compilation, at every start.
- The 18.9 M left run before the library: a Zig program on this host
  whose `main` takes `std.process.Init` retires 17.2 M and does
  nothing, one whose `main` takes no argument 10.8 M, and
  `/usr/bin/true` 7.9 M.
- Verifying every routine of the image as it loads (`docs/VM.md` §5)
  costs 0.35 M instructions, 1.6% of a start (21.85 M [21.52–23.17]
  without, 22.20 M [21.96–22.96] with, 21 interleaved rounds), for a
  fact the build's generator already proved of the same bytes: release
  builds skip it (`docs/STDLIB.md` §1).

### 3.19 Fast dispatch, Apple M5

The cost of one iteration or call of the micro programs
(`bench/micro/`, `docs/BENCH.md` §13) in machine instructions retired
and cycles, with the fast dispatch of `docs/VM.md` §8: frameless fast
handlers for the hot opcodes, `pc` in a register, every routine
verified once so the fast handlers check no bound and read a slot a
word at a time, and a fast `call:return` that fills the cell of a frame
a native pushed. Five interleaved rounds at a load of 4–6, medians
(instructions / cycles). Provenance: §11.

| Program | Instructions / cycles |
|---|---:|
| `count` | 117.0 / 14.4 |
| `acc` | 188.0 / 25.8 |
| `fib`, per call | 297.5 / 50.4 |
| `gcall` | 297.0 / 34.6 |
| `lc` (`count` + `mov:load-const`) | 139.0 / 21.9 |
| `lv` (+ `var:load-var`) | 145.0 / 19.0 |
| `mv` (+ `mov:move`) | 143.0 / 19.5 |
| `kw` (+ a keyword lookup) | 320.2 / 41.5 |
| `leaf` (+ a leaf native call) | 400.0 / 51.8 |
| `getnl` (+ a native call through its buffer) | 516.1 / 69.5 |
| `cbsum` less `cbbase`, per element | 85.1 / 21.1 |
| `cbred` less `cbbase` | 229.5 / 45.8 |
| `cb` less `cbbase` | 250.9 / 46.9 |
| `lazy` less `cbbase` | 334.8 / 69.2 |
| `lazy3`, 201 MB peak | 433.5 / 107.4 |

Startup (`-e nil`) retires 0.6 M more instructions for verifying the
boot's top-level forms, its wall time inside the run's spread.

What each step bought, and its limit:

- The frameless fast handlers alone moved cycles little: each dispatch
  stored `frame.pc` and the next loaded it, a chain carried from one
  instruction to the next. With `pc` in a register the chain is gone
  (`count` 175.0 → 158.9 instructions, 18.9 → 17.4 cycles). `acc`'s
  cycles fell only with `pc` in a register: both the chain through
  `frame.pc` and its loop's chain through the slots bound it before.
- Verified once per routine (`docs/VM.md` §5, §8), the fetch and the
  fast handlers check no bound (`count` 158.0 → 117.0 instructions). The
  fast handlers read a slot's value a word at a time, as it was stored:
  a handler reading a slot's kind byte, or both words in one 16-byte
  load, right after the handler before it stored the value as two
  words, waits for the store to reach the cache (without the word
  reads `acc` took 39.7 cycles against 28.6, `lv` 29.6 against 23.9).
  `lc` and `lv` stay bimodal across runs, as the address of the stack
  against the constant pool or the Var changes from run to run.
- The fast `call:return` filling the cell of a frame a native pushed
  (a `Callback`, `callValue`): `cbred` 264.1 → 229.2 instructions, `cb`
  285.7 → 250.6, `lazy` 369.7 → 334.7, and `fib` 302.5 → 297.5 a call.
- The fast handlers each on a cache line: every median lower by
  0.6–2.2 cycles, every range overlapping the other's.

**The runtime's place on the stack.** After the frame pointer was
dropped, the pipeline's timed phase ran 45 → 56 ms while its
instructions fell (949 → 816 M) and its cycles rose (157 → 209 M); each
stage alone ran faster, only the four together slower; 256 or 1,024
bytes more of native stack under a callback, or the frame pointer kept,
put it back at 44 ms. The `Runtime`, and the VM in it, lived on the
runtime thread's stack at a fixed distance from the frames of the
natives a callback runs under, so a native's store a multiple of 4 KiB
from a VM field made the next handler's load of the field wait; which
store did depended on the frames' sizes. The `Runtime` lives on the
heap (`src/cli.zig`), and the phase runs 37.7 ms.

### 3.20 The speed phase, Apple M5

The loop shape (§3.16), the image (§3.18) and the fast dispatch
(§3.19) together, against the tree before them, one ReleaseFast
`bin/nexis` of each. Provenance: §11.

The micro kit, seven interleaved rounds at a load of 5.1–6.6:
instructions and cycles an iteration, a call or an element, medians.
The instructions fell by 35–57% on every program but the callbacks
(`cbsum` −1.5%, `cb` −8.5%, `lazy` −8.0%, `cbred` −23%).

| Program | Instructions | Cycles |
|---|---:|---:|
| `count` | 106.9 | 13.3 |
| `acc` | 152.0 | 27.7 |
| `fib`, per call | 297.4 | 50.7 |
| `gcall` | 287.0 | 33.1 |
| `lc` | 129.0 | 21.9 |
| `lv` | 135.0 | 20.5 |
| `mv` | 133.0 | 20.5 |
| `kw` | 310.0 | 36.6 |
| `leaf` | 364.0 | 46.8 |
| `getnl` | 506.0 | 66.6 |
| `cbsum` less `cbbase` | 85.2 | 21.4 |
| `cbred` less `cbbase` | 229.5 | 45.3 |
| `cb` less `cbbase` | 250.9 | 44.6 |
| `lazy` less `cbbase` | 335.1 | 70.5 |
| `lazy3`, peak RSS 199 MB | 433.4 | 109.1 |

The `bench/compare` language rows, whole process under `/usr/bin/time
-l` (five interleaved rounds, medians; startup is in it) and the phase
each program times itself, the median of `run.clj`'s ten rounds, with
the resident set. Every answer was equal in every run and no row holds
more memory.

| Row | Instructions | Phase | RSS |
|---|---:|---:|---:|
| startup (`-e`) | | 4.11, 4.21 ms | 4 MB |
| loop/recur, 1M | 284 M (−52%) | 8.1, 8.5 ms | 4 MB |
| fib 30 | 824 M (−40%) | 35.1, 33.2 ms | 4 MB |
| destructuring loop | 4,334 M (−30%) | 179, 179 ms | 22 MB |
| map/filter/reduce over 1M maps | 2,670 M (−13%) | 39.0, 39.6 ms | 188 MB |
| vector conj and nth, 1M | 1,196 M (−14%) | 45.3, 46.0 ms | 34 MB |
| string build and split, 1 MB | 347 M (−15%) | 12.7, 12.7 ms | 31 MB |
| `frequencies` and `group-by`, 1M | 1,682 M (−13%) | 81.0, 79.1 ms | 59 MB |
| map through transients, 1M | 2,260 M (−17%) | 321, 313 ms | 85 MB |
| map build and read, 1M | 3,850 M (−11%) | 596, 624 ms | 96 MB |
| sort, 1M ints | 2,649 M (−4.7%) | 98.1, 97.1 ms | 153 MB |

The rows whose time is the interpreter's (loop, fib, destructuring,
the pipeline, vector `conj`/`nth`, string splitting, startup) ran
6–44% faster in every run, and `frequencies`/`group-by` 5%. The rows
whose time is the natives' moved within the spread of their runs: the
transient map, the map build and `sort`.

### 3.21 Calls and callbacks, Apple M5

What one iteration, call or element of the micro programs
(`bench/micro/`, `docs/BENCH.md` §13) costs in machine instructions
retired and cycles with the call path of `docs/VM.md` §6–§7: medians
of five interleaved rounds. Provenance: §11.

- **A leaner call and return.** The frame drops its `slot_count` and
  `return_pc` (the caller's own `pc` is its return point) and is 64
  bytes, one cache line; a call no longer counts the closure's cells
  against its routine's upvalues or, in a release build, moves the
  stack and frame high-water marks; the fast `call:call` tests for a
  closure first and fetches the callee's first instruction through the
  routine in hand. `fib` 297.5 → 280.5 instructions a call, `gcall`
  287.0 → 270.0.
- **Slots the verification proved.** The fast handlers trust the
  slots verification proved (§8). Asserted as
  `std.debug.assert(index < frame.routine.slot_count)`, which a
  release build assumes, the bound read through the frame's routine
  moved the routine's load to the top of every fast handler, and the
  counting loop ran 20–24 cycles an iteration against 12–14 with the
  same 107 instructions. Debug and safe builds assert it; release
  builds do not assume it (`VM.proved`).
- **A callback's call entered at its callee.** A `Callback`'s call of
  a closure makes the run loop's first pass itself: it sets the
  loop's depth and nesting, takes the safe point of the loop's entry
  and calls the callee's first handler directly, so neither `loop` nor
  its tests run per element; only an error goes on to the loop
  (`docs/VM.md` §6). The return of a frame a host pushed ends the
  chain without testing whether the loop's frame has returned, the
  result cell is read without a copy through the stack, and a safe
  point reads the heap's counter against its limit before the four
  flags that can switch collection off (`VM.gcDue`). `cbred` 226.3 →
  206.2 instructions an element (−8.9%), `cb` 241.8 → 219.7, `lazy`
  330.3 → 304.4, `cbsum` 85.2 → 78.2; `freq-group` 1,654 → 1,536 M
  whole process (−7.1%) and its phase 76.6 → 65.3 ms.
- **The deep-data check inline.** Every call of a native that is not a
  leaf compares the spoil counter before and after
  (`VM.checkDeepData`, `docs/VM.md` §13.1). Inline, the common case is
  the read and a compare, and the raise is a call of its own: `getnl`
  500.0 → 476.0 instructions, `destructure` 4,260 → 4,099 M (−3.8%).
- **A native's call block cleared after the call** (a memory lever,
  `docs/VM.md` §6). It costs about ten instructions a call of a native
  that is not a leaf (`getnl` +2.1%, `destructure` +1.0%), against the
  24 the inline check saved; less marking pays for it in `lazy3`, whose
  inner seqs, 138 MB of them, are garbage once the call that took each
  has returned: 1,218 → 1,095 M instructions (−10%), peak 199.2 →
  61.2 MB. A first build lost 61 instructions a non-leaf native call:
  with the clearing after it, the optimizer folded the inline copy of
  the arguments and the copy past the stack's capacity into one call of
  `memcpy`; the second copy is a function of its own.
- **Natives that consume their sequence** (a memory lever,
  `docs/GC.md` §11.5): `reduce`, `frequencies`, `group-by`, `some`,
  `every?`, `last` and `dorun` have their last argument's slot cleared
  by `call:call` and keep only their walk's place rooted. `lazy3`
  1,094.7 → 1,009.4 M instructions (−7.8%), peak 61.2 → 21.3 MB;
  `freq-group` peaks 58.7 → 41.1 MB, where an eager build of the
  sequences peaks (40 MB): the mapped seq `frequencies` counts is
  garbage behind its walk. The pipeline row stays at 187.7 MB: no
  cycle runs in its phase (§3.14), and its rows are the 1M maps the
  setup built.

The `bench/compare` and database rows moved within their spread under
the first four changes.
### 3.22 Leaf natives, Apple M5

The natives the `bench/compare` language rows call once an iteration
or an element, counted by a `-Dopcodes=true` build (`docs/TOOLING.md`
§1), are leaves with a general body (`docs/VM.md` §6): `get`, `count`,
`nthnext`, `seq?` and the other kind predicates, `conj`, `assoc`,
`assoc!` and `str`, beside `nth` and the arithmetic. Each is called in
place, without the argument buffer, the spoil snapshot or the overflow
check, and refuses what could run code or walk nested data. A call
through the buffered path costs 55–86 instructions more than the same
call as a leaf. Provenance: §11.

The micro programs (`count` plus one call an iteration), five
interleaved rounds at a load of 7.8–9.9, instructions / cycles an
iteration, medians:

| Program | Instructions / cycles |
|---|---:|
| `get` of a vector (`getnl`) | 447.1 / 59.0 |
| `get` of a map by a keyword | 504.0 / 67.5 |
| `count` of a vector | 351.3 / 44.4 |
| `seq?` | 325.0 / 50.3 |
| `nthnext` of a vector | 528.6 / 69.2 |
| `conj` onto a vector | 743.9 / 105.6 |
| `assoc` into a map | 674.1 / 102.9 |
| `assoc!` into a transient map | 659.2 / 104.7 |
| `str` of a fixnum | 726.3 / 86.5 |

The `bench/compare` programs, each whole process, seven interleaved
rounds: the destructuring loop −8.6% instructions (3,963 M), vector
`conj` and `nth` −16.6% (997 M), string build and split −12.6% (303
M), the transient map −5.0%, the map build −3.2%; the loop, `fib`,
pipeline, `sort` and `frequencies`/`group-by` unchanged. Phase, median
of ten rounds: destructuring loop 150, 156 ms, vector `conj` and `nth`
38.6, 40.5 ms, string build and split 9.99, 11.1 ms. The two map rows'
time is the map's construction, which the leaf calls do not change;
their runs spread by 20%.

### 3.23 Self-calls, Apple M5

A `fn*` calling its own name with its fixed arity, from its own body,
is `call:self` (`docs/COMPILER.md` §5.5, `docs/VM.md` §6): no move of
the closure out of its cell into the call block, no callee kind or
arity test, and no cell at all when the name is used only so. `fib`'s
body is 9 instructions instead of 11. Provenance: §11.

Per unit, `harness.py` at two sizes, seven interleaved rounds, the
median of the paired differences, the range in brackets:

| Program | Instructions | Cycles |
|---|---:|---:|
| `fib`, a call | 236.5 [234.3–236.6] (−15.7%) | 40.7 [31.8–41.6] |
| `count`, `gcall`, `lc`, `kw` | unchanged | unchanged |

The `bench/compare` `fib` row, whole process: 659.4 M instructions
(−15.2%), 118.0 M cycles; its phase 25.6, 25.7 ms. The other programs
are within 0.3% and every resident set the same.

### 3.24 The keyword lookup instruction, Apple M5

`(:k x)` and `(:k x d)` with a keyword or symbol literal are one
`call:lookup` or `call:lookup-or` (`docs/COMPILER.md` §4.3,
`docs/VM.md` §6) instead of a `mov:load-const` of the keyword, a move
of each argument and a `call:call`; the target is read in place. The
lookup itself, `champ`'s search of the map, is unchanged. A map
pattern's keyword or symbol key is the key's call on the source
(`docs/MACROEXPAND.md` §10), so `{:keys [a b]}` binds by two
`call:lookup` where it called `get` twice through its Var. Provenance:
§11.

Per unit, `harness.py`, seven interleaved rounds:

| Program | Instructions | Cycles |
|---|---:|---:|
| `kw`, `(recur (inc i) (:b m))` | 259.0 [258.4–259.1] (from 310.0, −16.5%) | 31.6 [30.0–33.1] |
| `destr`, `(+ acc (let [{:keys [a b]} m] (+ a b)))` an iteration | 663.1 [662.5–663.4] (from 1,055.1, −37.2%) | 79.5 [77.2–81.8] |

On the `bench/compare` programs, whole process: the pipeline, whose
filter is `(even? (:group row))`, −2.1% instructions (2,490.9 M), phase
36.1, 37.6 ms; the destructuring loop −10.2% (3,462.2 M instructions,
558.5 M cycles), phase 139, 137 ms against babashka's 333–368 ms. The
other language rows are within 0.1%, every resident set the same.

### 3.25 Quickening, Apple M5

The compiler quickens each routine it finishes (`docs/VM.md` §10.10,
`docs/COMPILER.md` §4.5): a `cmp` instruction or a `math:add`, `sub`,
`mul`, `idiv` or `mod` of slots, of a slot and a fixnum constant or
(`math`) of a fixnum constant and a slot, a `mov:move` of a slot or an
upvalue and a `call:return` of a slot take a variant whose fast
handler decodes no operand kind, and a comparison followed by its
conditional jump says so, so it runs the jump without looking for it.
The fast handlers of `math:add` and `cmp:lt` are 116 and 129 arm64
instructions, all kinds; their quickened ones 36 to 50 (`zig build
codegen`); on x86-64 the quickened comparisons save no register where
the general ones save three. Provenance: §11.

Per unit, `harness.py` at two sizes, seven interleaved rounds, the
median of the paired differences, the range in brackets:

| Program | Instructions | Cycles |
|---|---:|---:|
| `count` | 73.0 [72.3–73.0] (−31.7%) | 9.6 [8.8–10.3] |
| `acc` | 110.0 [110.0–110.0] (−27.6%) | 12.6 [10.1–15.1] |
| `fib`, a call | 186.0 [185.9–186.0] (−21.3%) | 25.6 [25.0–25.7] |
| `gcall` | 232.0 [230.9–232.1] (−14.1%) | 29.7 [26.3–30.9] |
| `lc` | 95.0 (−26.4%) | 12.3 [11.6–12.9] |
| `mv` | 94.0 (−29.3%) | 11.6 [11.1–12.2] |
| `lv` | 101.0 (−25.2%) | 13.1 [12.8–13.8] |
| `kw` | 225.0 (−13.1%) | 29.9 [28.7–31.4] |
| `leaf` | 313.9 (−12.3%) | 40.1 [37.8–41.0] |
| `getnl` | 395.0 (−10.6%) | 49.7 [49.1–53.5] |
| `destr` | 603.0 (−9.1%) | 75.6 [70.3–82.9] |
| `cbred` less `cbbase`, an element | 196.0 (−5.3%) | 39.3 |

`acc` ran half its cycles: its loop carries `i` and `acc` through
slots, and each handler, with no kind to decode, reaches its store
sooner. `cb`'s cycles rose in every round while its instructions fell:
its callback `(fn [x] x)` runs only a quickened `call:return`, and
the 48 handlers more in the hot section move the others against each
other.

The `bench/compare` programs, whole process (instructions, change):
`loop` 212.7 M (−25.0%), `fib` 523.3 M (−20.6%), the destructuring loop
3,337.9 M (−3.6%), the pipeline 2,437.9 M (−2.1%),
`frequencies`/`group-by` 1,468.6 M (−4.3%), the map build 3,561.9 M
(−1.4%), the transient map 1,961.9 M (−2.6%), `sort` 2,598.4 M
(−1.3%), string split 293.6 M (−1.3%), vector `conj`/`nth` 903.5 M
(−2.6%); every resident set the same. The pipeline's and the transient
map's cycles rose in the medians and not in every round. Phases
(`run.clj`): `loop` 5.46, 5.37 ms, `fib` 16.7, 16.9 ms, the
destructuring loop 127, 130 ms, the pipeline 34.1, 34.3 ms against
babashka's 45.7–46.7 ms. Startup is unchanged (`-e nil` 21.74 M
instructions, 3.93 ms): the image holds quickened code and loading it
rewrites nothing.

### 3.26 The counting-loop step, Apple M5

A counting loop's `(inc i)` just before its repeated test is a step
(`docs/VM.md` §10.10): one dispatch runs the add, the comparison and
its branch back, where the add and the quickened pair were two. The
step's fast handlers are 61 arm64 instructions with a fixnum limit
and 70 with a slot (66 and 72 on x86-64, the slot form saving one
register), against 36 to 50 for each of the two it replaces
(`zig build codegen`). Provenance: §11.

Per unit, `harness.py` at two sizes, seven interleaved rounds, the
median of the paired differences, the range in brackets:

| Program | Instructions | Cycles |
|---|---:|---:|
| `count` | 58.0 [57.9–58.0] (−20.5%) | 8.3 [8.1–8.6] |
| `acc` | 95.0 [95.0–95.0] (−13.6%) | 11.3 [9.7–13.4] |
| `fib`, a call | 186.0 (unchanged) | 25.7 [25.0–27.4] |
| `gcall` | 232.0 (unchanged) | 31.2 [27.5–33.1] |

`gcall` calls between its `(inc i)` and its test, so it keeps its two
dispatches. Only `loop` (−6.9%, 197.8 M instructions) and the
destructuring loop (−0.45%, 3,317.6 M) of the `bench/compare`
programs count with a step; every other program is unchanged and every
resident set the same. `run.clj` phases: `loop` 4.88, 4.88 ms, the
destructuring loop 122, 125 ms, `fib` 16.1, 16.1 ms, the pipeline
32.4, 32.1 ms against babashka's 43.2–44.7 ms.

### 3.27 Small transactions, Apple M5

What one `transact!` costs, and where it goes. The figures below are
format 2's; format 3 (§3.36) dirties 15 to 17 pages for these shapes
and retires 20–34% fewer instructions, a new entity writing no
history tree. A probe program loads 20,000 people into a fresh store,
then runs N transactions of one shape; a transaction's cost is the run
of 10,000 less the run of 2,000, over 8,000. Every figure is an
optimized build's: a debug build takes about 750 μs a transaction.
Trees open on first use (§6). Nine interleaved rounds, the median of
the paired differences, the instruction range in brackets. Provenance:
§11.

| Shape | pages | instructions | cycles | μs |
|---|---:|---:|---:|---:|
| new entity, 4 attributes | 27.1 | 204.7k [203.0–205.0] | 60.2k | 16.2 |
| new entity, 5 attributes, one unique | 31.1 | 243.8k [243.1–244.4] | 73.6k | 20.4 |
| upsert through the unique email, 5 attributes, 1 changed | 19.1 | 168.1k [166.7–168.4] | 45.7k | 12.5 |
| one datom through a lookup ref (§3.11's shape) | 19.1 | 157.2k [157.0–157.7] | 44.4k | 11.5 |

The resident set is 68–79 MB. *Pages* are the pages a transaction
dirties, 16 KiB each, counted from emdb's dirty-page table before each
commit. The instructions follow them, about 8,000 a page: emdb copies
each page a transaction first writes and checksums it at commit. Where
they go, from `perf record -e instructions:u` with LBR call stacks on
the Linux host of §3.15, the five-attribute shape over 200,000
transactions:

| Where | share |
|---|---:|
| emdb: the index, txlog and `sys` puts (copy-on-write, searches, inserts) | 55.1% |
| emdb: the commit (writing and sealing pages, tree records, the free list) | 15.2% |
| emdb: reads (`sys`, the AVET probes, the card-one lookups) | 6.4% |
| emdb: the rest | 2.6% |
| Nextomic and the VM | 20.7% |

Nextomic's own part is spread thin: packing and sorting each index's
keys for the batch (4.9%), the txlog entry (3.1%), the report (3.0%),
expansion (2.7%), normalising the tx-data (2.5%), the
`:db/txInstant` datom (1.1%), the rest under 1% each. Opening all
twelve trees in the write transaction and again in the report's read
was 8.0% of the instructions.

`bench/compare`'s database rows (§3.11's harness, Nextomic alone),
medians of two runs: `tx-entity-1k` (new entity, 5 attributes) 24.7,
25.5 ms, `tx-upsert-1k` 13.0, 13.0 ms, `tx-1k-default` 13.2, 12.9 ms,
`lookup-10k` 10.5, 10.9 ms, `join3-20x` 9.80, 9.68 ms, `aggregate`
18.1, 17.7 ms, `pull-10k` 7.53, 7.38 ms, `open` 135, 130 μs, `load`
303, 274 ms; the query process's peak RSS is 133–135 MB. The store's
100,000 people put the one-entity transaction at 25 μs, its pages
deeper than the probe's 20,000. Beside Datalevin 1.1.0: one-entity
transactions 21.6 ms against 460 ms a thousand, upserts 13.2 ms
against 299 ms, one-datom transactions 13.3 ms against 241 ms in each
system's default commit (Datalevin's syncs; Nextomic's does not,
§3.11), and 22.6 ms against 59.2 ms with the flush off in both.

### 3.28 Multimethod dispatch, Apple M5

A multimethod call (`docs/STDLIB.md` §9.3) against a protocol call, a
closure call and a `case`, each a three-way dispatch on one value per
iteration of the micro kit (`docs/BENCH.md` §13): `mcall` calls a
multimethod dispatching on `:shape`, every call a cache hit; `pcall` a
protocol method on a record; `casek` a `case` over `(:shape m)`. The
cache hit is one leaf native, `#%mm-lookup`, in place of two `deref`s,
two `nth`s, an `identical?` and a `get` (−29.0% instructions). One
ReleaseFast build, before §3.26's counting-loop step, so `count` is
72.9 here. Provenance: §11.

Per unit, `bench/micro/run.clj`, five interleaved rounds, the median
with the range in brackets:

| Program | Instructions | after less `count` | Cycles |
|---|---:|---:|---:|
| `count` | 72.9 [71.9–73.3] | — | 10.1 |
| `gcall` | 232.1 [231.9–232.6] | 159.2 | 34.3 |
| `pcall` | 674.5 [674.4–675.1] | 601.6 | 91.0 |
| `casek` | 724.3 [724.0–724.7] | 651.4 | 102.6 |
| `mcall` | 2,162.0 [2,161.3–2,164.0] | 2,089.1 | 422.7 |

A multimethod call costs 3.5 protocol calls and 13.1 closure calls,
against the design target of 2 and 6: the target is missed. The
`-Dopcodes=true` counts say where it goes: an `mcall` iteration is 29
dispatches and three native calls (`#%mm-lookup`, `count`, `first`)
where `pcall`'s is 6 and none. The multimethod is a multi-arity `fn`,
which the expander lowers to one variadic routine that counts its rest
list and picks the arity (`docs/MACROEXPAND.md` §10), so every call
allocates the rest list (`mcall`'s peak resident set is 22.4 MB at 10 M
calls, `pcall`'s 4.5 MB) and calls `count` and `first` before its body
runs. The same fast path as a one-arity closure costs 1,153
instructions less `count`: 1.9 protocol calls and 7.2 closure calls, so
per-arity entry points for a multi-arity `fn` would meet the first
target and come near the second; §3.30 measures them.

### 3.29 Locals clearing, Apple M5

The compiler clears a local's slot at its last move
(`docs/COMPILER.md` §4.9): `mov:move-clear` (`docs/VM.md` §10.1) is
`mov:move.s` and one store of a pair of zero words, 22 arm64
instructions against 21 and 25 x86-64 instructions against 23
(`zig build codegen`). Provenance: §11.

What a lazy seq a local or a parameter holds keeps, whole process,
three interleaved runs (load 4.8 → 5.3), the peak resident set and
the median instructions and wall time:

| Program | n | Peak RSS | Instructions | Wall |
|---|---:|---:|---:|---:|
| `lazy3`, the pipeline passed straight to `reduce` | 3 M | 21.4 MB | 1,015 M | 74 ms |
| | 30 M | 21.9 MB | 11,147 M | 650 ms |
| `lazyl`, the pipeline bound by `let`, then `(reduce + s)` | 3 M | 21.4 MB (from 61.4) | 1,013 M | 69 ms |
| | 30 M | 22.0 MB (from 588.8) | 11,145 M | 671 ms |
| `lazyf`, the pipeline through `(defn total [xs] (reduce + xs))` | 3 M | 21.5 MB (from 61.5) | 1,012 M | 71 ms |
| | 30 M | 22.0 MB (from 588.8) | 11,145 M | 632 ms |

Bound by a local or passed to a fn, the pipeline costs what it costs
passed straight in: the collector no longer marks the realized chain
at every cycle.

A clear costs one instruction, the zero store: `mvc` (one clear an
iteration) is 116.0 instructions against `mv`'s 94.0 and `leaf` 300.1
against 299.1; every other program of the micro kit is the same within
its range (`lazyl` and `lazyf` fall from 371.4 to 327 instructions an
element, 110 to 72 cycles). The pass runs before quickening and
rewrites only moves, so the counting loop's step (§3.26) still runs
every iteration of `count`, `acc` and `leaf`.

In the `bench/compare` language programs every row is within its range
but `sort`, whose input vector is garbage once `sort` has it:
2,603.8 → 2,582.5 M instructions and 154.4 → 137.7 MB. Startup (`-e
nil`) is 22.02 M instructions, within the range of the 21.95 M before.
`compile_simple` is 361–395 ns, `eval_simple_loop` 1.96–2.02 μs and
`closure_create` 806 ns, none moved by the pass; the stdlib image's
generator, a debug build that also checks every routine it clears in,
runs 498 → 535 M instructions (58 → 63 ms).

### 3.30 Per-arity entry points, Apple M5

A multi-arity `fn` compiles to a routine per clause over one arity
table, and a call enters the clause its argument count picks
(`docs/VM.md` §5, §6; `docs/COMPILER.md` §5.5), not one variadic
routine that builds a rest list, counts it and binds each clause's
parameters with `first` and `nth` (`docs/MACROEXPAND.md` §10).
Provenance: §11.

The micro kit (`docs/BENCH.md` §13), `bb bench/micro/run.clj
--rounds 5`, instructions and cycles per unit, the median and the
range of the paired rounds, and the peak resident set at the larger
size:

| Program | Instructions | Cycles | Peak RSS |
|---|---:|---:|---:|
| `gcall`, a one-arity call | 231.0 [231.0–231.0] | 29.7 | 4.3 MB |
| `acall`, a three-clause fn at its one-argument clause | 237.0 [236.9–237.0] (from 1,170.8) | 30.1 | 4.3 MB |
| `vcall`, its variadic clause, one argument in its rest | 713.8 [713.5–713.9] (from 2,024.1) | 93.3 | 22.0 MB |
| `fib`, a call | 190.0 [189.9–190.1] | 25.2 | 4.2 MB |
| `afib`, a call, each into the other clause | 169.5 [169.5–169.5] (from 1,314.4) | 25.2 | 4.2 MB |
| `pcall`, a protocol method | 674.0 [674.0–674.1] | 88.5 | 4.4 MB |
| `mcall`, a multimethod | 1,233.0 [1,230.7–1,233.1] (from 2,169.0) | 187.3 | 4.6 MB |
| `xform` less `cbbase`, a transducer step an element | 460.8 [460.1–461.5] (from 1,924.3) | 69.4 | 70.1 MB |

A call of a clause costs a one-arity call and 6 instructions, the
table's test, bounds check and load (`zig build codegen`: `fastCall`
92 → 99 arm64 instructions, 134 → 142 on x86-64, the same 6 registers
saved). On `-Dopcodes=true` builds an `acall` iteration dispatches 6
instructions and calls no native, as `gcall`'s does, where the variadic
routine dispatched 14 and called `count` and `first`; an `afib` call
4.25 dispatches, `fib`'s 4.5; an `mcall` iteration 21 and one native
(`#%mm-lookup`). A call that allocates nothing never fills the
collector's window, so the peak resident set falls to a one-arity
program's; `vcall` still builds its rest list. Less `count`, as §3.28
counts them, the multimethod costs 1.91 protocol calls and 6.8 closure
calls (1,175.1 against 616.1 and 173.1), inside §3.28's target of 2
protocol calls and near its 6 closure calls. Every other program of
the kit and of `bench/compare` is within its range; none of the
latter calls a multi-arity fn in its loop. Startup (`-e nil`) is 22.28
M instructions. The stdlib image, whose multi-arity `defn`s,
transducer step fns and overloads carry 42 tables, is 221,190 bytes: 463
routines, 6,575 instructions, 598 constants.

### 3.31 Consuming natives, Apple M5

`count`, `into`, `vec`, `take-last`, `i64-vector` and `f64-vector`
consume their sequence argument (`docs/GC.md` §11.5), as `reduce`
does, so a lazy seq a local holds is let go as they walk it.
Provenance: §11.

Each program binds the pipeline `(map inc (filter even? (map inc
(range n))))` (`lazyi` maps `#(mod % 10)` last) by `let` and hands it
to the native; whole process, three interleaved runs (load 5.9 → 6.4),
the peak resident set and the median instructions and wall time, with
the peak before the change in brackets:

| Program | n | Peak RSS | Instructions | Wall |
|---|---:|---:|---:|---:|
| `(count s)` | 3 M | 21.6 MB (61.5) | 910 M | 75 ms |
| | 30 M | 21.6 MB (587.4) | 8,827 M | 578 ms |
| `(count (into #{} s))`, ten distinct | 3 M | 21.7 MB (111.2) | 1,531 M | 97 ms |
| | 30 M | 21.6 MB (1,069.2) | 15,028 M | 897 ms |
| `(count (into #{} (map #(mod % 10)) s))` | 3 M | 22.3 MB (71.1) | 4,297 M | 265 ms |
| | 30 M | 22.3 MB (655.1) | 42,728 M | 2,300 ms |
| `(count (vec s))` | 3 M | 48.2 MB (112.4) | 1,045 M | 74 ms |
| | 30 M | 435.7 MB (967.7) | 10,622 M | 734 ms |
| `(count (i64-vector s))` and `(take-last 2 ...)` of the pipeline | 3 M | 47.9 MB (136.7) | 1,882 M | 134 ms |
| | 30 M | 367.8 MB (1,333.7) | 18,599 M | 1,318 ms |

What `count` and `into` a set keep is their walk's place; `vec` keeps
the vector it builds, 16 bytes an element. The collector does not mark
the realized chain at every cycle, which is the instructions the rows
lose.

`into` a hash set of 1.5 M (3 M) and 15 M (30 M) distinct elements
conj's each on a transient as the walk hands it out, where it
collected every element before conj'ing them on the same transient:
peak 209.7 → 97.0 MB and 1,825.4 → 815.5 MB at the same instructions.
`set` is left as it is: it builds its set from every element at once,
each node allocated once, and conj'ing each on a transient instead ran
960 → 1,392 M cycles at 3 M and 10,893 → 20,785 M at 30 M, the same
instructions.

Every micro-kit program and every `bench/compare` language program is
within its range and 0.3% in instructions, every peak resident set the
same.

### 3.32 Sort keys compared in registers, Linux x86-64 and Apple M5

`sort` and `sort-by` in the natural order compare two fixnum keys in
place, and any other pair through `sorted.naturalOrder` directly,
reading its `OrderError!Order` as it is (`SortOrder.less` in
`src/stdlib.zig`). Through `compareValues` the result is converted to a
`VmError!Order` first, which Zig 0.17's x86-64 code rebuilds on the
stack as a 16-bit and an 8-bit store and reads back as one 32-bit load
the store buffer cannot forward (`sort` spent half its cycles in
`mergeSort`, three quarters of those at that one load; built by Zig
0.16 the same program ran the phase in 144 ms against 181 ms, 1.4%
fewer instructions in 21% more cycles); read directly, the error and
the order are loads of their own widths, and the fixnum path calls
nothing. One ReleaseFast build on each host. Provenance: §11.

The `bench/compare` `sort` program (a million scrambled ints) and the
same over 300,000 distinct strings, each program's own phase time and
the whole process's instructions and cycles, the median of interleaved
runs. Linux x86-64, `taskset -c 2`, `perf stat -e
cpu_core/instructions/u,cpu_core/cycles/u`, five rounds; the build
before the change in brackets:

| Host | ints: phase | instructions | cycles | strings: phase | instructions | cycles |
|---|---:|---:|---:|---:|---:|---:|
| Linux x86-64 | 92.7 ms (180.4) | 1,194.9 M (2,672.0) | 442.2 M (862.0) | 78.0 ms (92.9) | 1,210.9 M (1,292.1) | 434.7 M (508.1) |
| Apple M5, `/usr/bin/time -l` | 52.9 ms (89.2) | 1,187.5 M (2,568.6) | 280.9 M (428.2) | 53.4 ms (54.7) | 1,226.4 M (1,258.6) | 261.9 M (269.0) |

`bench/compare/run.clj --only lang --impls nexis,bb --workloads sort`
on the Linux host, two passes: nexis 96.3, 93.8 ms against babashka's
391, 372 ms (0.25 of its time, from 0.47–0.50), wall 135, 133 ms, 119 MB
resident against 116 MB.

What the rows say:

- The fixnum path is the larger part: alone it halves the int sort on
  both hosts (1,415 M instructions fewer on x86-64: a call to
  `naturalOrder` and its stack check per comparison), and on x86-64 it
  also takes those comparisons off the stalled load, so cycles fall
  nearly as far as instructions.
- The direct call removes the stall itself: alone it takes the int sort
  on x86-64 from 181.6 to 132.5 ms, and the string sort, where every
  comparison takes the general path, from 93.5 to 77.8 ms and 509.5 to
  432.2 M cycles (−15%). On the M5, whose stores forward, it saves
  instructions only: the string sort −4.3% without the fixnum test,
  −2.6% with it.
- The fixnum test costs the string sort 14 M instructions on x86-64
  and about 20 M on the M5, a few per comparison, within the cycle
  range on both hosts.
- The int sort runs in 93–96 ms on the Linux host, below the warm JVM
  Clojure figure of §3.15 (147 ms) and a quarter of babashka's time;
  its resident set is unchanged (its buffers are §3.34's).

### 3.33 Closures called from natives, Linux x86-64 and Apple M5

A native that calls a closure once per element (`reduce`, `mapv`,
`filterv`, a lazy `map`, `filter` or `remove`) calls it through a
`vm.Callback` (`docs/VM.md` §6, "Repeated calls" and "Batched
calls"). Three changes:

- **A1, the producer step's call inline:** a lazy producer's
  per-element `apply` was a call of its own, its argument through a
  stack array and its `?Value` result built in memory; inline, the
  callback lands in the chunk loop. `isReduced` tests the kind before
  the home's reduced type.
- **A2, a leaner prepared call:** `call1` and `call2` store their
  arguments into the window as words, straight from registers; the
  frame returns into a cell of the `Callback`'s own, read back as
  words; `callPrepared` returns only an error; the locals are nil'd in
  one run of four.
- **B, batches:** `each`, `fold` and `foldRange` make a run's calls in
  one pass of the chain, the return of each element's frame going on,
  out of line, to the next element in the same frame; the natives
  above walk their runs through them.

Provenance: §11. The micro kit (`docs/BENCH.md` §13), instructions an
element, the builds interleaved, five rounds:

| Program | before | A1 | A2 | B |
|---|---:|---:|---:|---:|
| `cbred` less `cbbase`: `(reduce (fn [a x] (+ a x)) 0 v)` | 198.6 | 195.1 | 165.4 | 100.9 |
| `cb` less `cbbase`: `(mapv (fn [x] x) v)` | 217.7 | 218.5 | 179.7 | 85.6 |
| `lazy` less `cbbase`: `(reduce + 0 (map (fn [x] x) v))` | 296.5 | 270.2 | 246.5 | 177.8 |
| `cbfilt` less `cbbase`: `(reduce + 0 (filter (fn [x] (even? x)) v))` | 394.8 | 361.9 | 334.6 | 278.1 |
| `xform` less `cbbase` | 464.5 | 460.1 | 426.3 | 360.6 |
| `cbrange`: `(reduce (fn [a x] (+ a x)) 0 (range n))` | 201.1 | 198.0 | 168.9 | 95.1 |
| `cbsum` less `cbbase`: `(reduce + 0 v)` | 79.8 | 75.2 | 72.9 | 68.5 |
| `lazy3` | 328.2 | 259.5 | 261.3 | 240.0 |

Linux x86-64, the `bench/compare` pipeline and vector rows,
`taskset -c 2`, `perf stat -e
cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/ld_blocks.store_forward/u`,
five rounds, medians:

| Row | Build | phase | instructions | cycles | blocked loads |
|---|---|---:|---:|---:|---:|
| `map`/`filter`/`reduce` over 1M maps | before | 60.4 ms | 2,519.5 M | 788.2 M | 19.03 M |
| | A2 | 51.8 ms | 2,382.9 M | 740.1 M | 18.43 M |
| | B | 46.8 ms | 2,207.4 M | 674.7 M | 14.58 M |
| vector `conj` and `nth`, 1M | before | 75.2 ms | 950.1 M | 332.0 M | 5.08 M |
| | A2 | 64.9 ms | 890.1 M | 282.8 M | 4.16 M |
| | B | 60.6 ms | 792.1 M | 260.3 M | 3.18 M |

`bench/compare/run.clj` on the Linux host, two passes: the pipeline
46.5, 46.4 ms against babashka's 49.0, 49.3 ms (0.95, 0.94, from 1.18,
1.19), wall 200 ms, 188 MB against 214 MB; vectors 63.2, 62.2 ms
against 121 ms (0.52, 0.51, from 0.65), wall 73 ms, 35 MB against 126
MB. On the M5, whole process, median instructions: `pipeline` 2,455.4
→ 2,153.6 M (−12.3%), `vector-conj-nth` 910.8 → 781.7 M (−14.2%),
`freq-group` 1,486.1 → 1,213.7 M (−18.3%), `map-transient` 2,025.9 →
1,798.1 M (−11.2%), `sort` 1,210.5 → 1,065.3 M (−12.0%, its setup's
`mapv` over a range), `string-split` 297.2 → 275.9 M, `map-build-read`
3,680.1 → 3,436.3 M; `fib`, `loop` and `destructure` the same within
0.2%; every peak resident set the same.

What the rows say:

- On x86-64 the 16-byte load of a result two 8-byte stores had just
  written was a stall: in `vm.VM.callPrepared` it was 84% of the
  function's blocked loads in the vector row (`perf record` of
  `ld_blocks.store_forward`). A2 reads the cell as words; an argument
  array stored as words and copied into the window as 16 bytes, in
  `fnReduce`, blocked in turn until A2 stored the arguments from
  registers. The vector row's cycles fell 15% with A2, against 6% of
  its instructions.
- B leaves about 60 instructions around a batched element on arm64:
  the return's test of its frame and the cell, then the part that
  stores the result, writes the next arguments and the locals, takes
  the safe point and dispatches the callee's first instruction, which
  the first call looked up. `callPrepared`, 8% and 10% of the vector
  and pipeline rows' sampled cycles before (the pipeline's largest
  share), is gone from both profiles; `Callback.foldRange` is 3% of
  the vector row's.
- Against the build before B, `cbred` and `cb` fell 39% and 52%,
  `lazy` 28%, the rest of whose cost is its chunks and `reduce +`'s
  leaf calls; against the build before A1, 49%, 61% and 40%.
- The dispatch and native counts (`-Dopcodes=true`) of every micro
  program, both rows and a probe of `reduced`, throws and nested
  batches are the same before and after: each element runs the
  instructions one call ran.
- On the Linux host the pipeline runs in 46 ms, ahead of babashka, and
  vectors in 62 ms; against §3.15's warm JVM Clojure figures (22.4 and
  30.3 ms) both are 2.1×, from 2.7× and 2.6×. What remains is the
  callee bodies' dispatches, the largest a leaf native called through a
  Var (`(nth v i)`, `(even? x)`; §6 "Inline caches at call sites").

### 3.34 Sort's buffers, Linux x86-64 and Apple M5

`sortImpl` (`src/stdlib.zig`) sorts the elements in the list it
gathers them into: the values alone when there is no key function, and
`{key, val}` pairs, whose values it writes back, when there is one.
Each merge copies its left half into a scratch array and merges into
place from the front, so the scratch array holds half the elements, and
it is freed before the result is built. Outside the heap, for a million
elements:

| Call | Buffers |
|---|---:|
| `(sort v)` | 24 MB: the list 16, scratch 8 |
| `(sort cmp v)` | 24 MB, the root stack 16 |
| `(sort-by f v)` | 64 MB: the list 16, pairs 32, scratch 16; the root stack 32 |

A merge over pairs whatever the order, through a scratch array of pairs
as long as the list with both halves copied into it, took 80 MB for
each. `SortOrder.less` is inline: `mergeSort` has an instance for
values and one for pairs, and called from both, the fixnum test of
§3.32 leaves the merge loop, the million-int sort retiring 1,174 M
instructions on the M5 against 778 M inline. Provenance: §11.

The programs: `bench/compare`'s `sort` (`prelude.nx` and
`lang/sort.clj`: a million scrambled ints sorted, then `(vec
sorted)`), the same `(sort v)` without the `vec`, `(sort-by - v)`,
`(sort > v)`, and §3.32's 300,000 strings; each program's own phase
time, the whole process's instructions, cycles and maximum resident
set, the median of interleaved runs.

Linux x86-64, `taskset -c 2`, `perf stat -e
cpu_core/instructions/u,cpu_core/cycles/u` under GNU `time`, five
rounds:

| Program | phase | instructions | cycles | resident set |
|---|---:|---:|---:|---:|
| `sort`, the `bench/compare` row | 54.5 ms | 929.2 M | 258.0 M | 55.9 MB |
| `(sort v)` | 46.1 ms | 844.6 M | 232.4 M | 55.4 MB |
| `(sort-by - v)` | 93.5 ms | 1,129.9 M | 381.4 M | 118.6 MB |
| `(sort > v)` | 179.1 ms | 2,969.1 M | 850.3 M | 71.4 MB |
| 300,000 strings | 67.4 ms | 1,123.4 M | 382.5 M | 31.0 MB |

Apple M5, `/usr/bin/time -l`, seven rounds under `tools/heavy`:

| Program | phase | instructions | cycles | resident set |
|---|---:|---:|---:|---:|
| `sort`, the `bench/compare` row | 53.7 ms | 857.9 M | 216.8 M | 80.5 MB |
| `(sort v)` | 43.7 ms | 772.6 M | 187.1 M | 64.1 MB |
| `(sort-by - v)` | 70.6 ms | 1,040.3 M | 268.8 M | 112.1 MB |
| `(sort > v)` | 159.8 ms | 2,563.4 M | 546.8 M | 80.1 MB |
| 300,000 strings | 75.7 ms | 1,131.2 M | 281.9 M | 36.3 MB |

`bench/compare/run.clj --only lang --impls nexis,bb --workloads sort`
on the Linux host, two passes: nexis 54.5, 55.6 ms against babashka's
331, 328 ms (0.16, 0.17 of its time), wall 82, 83 ms, 56 MB resident
against 116 MB.

What the rows say:

- Every program's resident set fell by what its buffers were: 56–64 MB
  for a million ints sorted by value, 33–40 MB by `sort-by`, 19 MB for
  300,000 strings. The `bench/compare` row peaks at 56 MB on the Linux
  host.
- The time falls with it, most on x86-64: a merge step moves a 16-byte
  value where it moved a 32-byte pair, a merge copies half its elements
  where it copied all, and a million elements' buffers take 24 MB of
  cache where they took 80. The int sort 91.5 → 54.5 ms on the Linux
  host, `(sort > v)` −18%, the strings −13%.
- `sort-by` retires 5% more instructions on x86-64 (4.5% fewer on the
  M5), in the pairs' instance of the merge, and runs 12% faster.
- On the M5 the `bench/compare` program peaks at `(vec sorted)`, 16 MB
  above `(sort v)` alone; §3.35 measures `vec` of a list that views a
  whole vector.

### 3.35 Consuming natives, the rest, Apple M5

`reverse`, `butlast`, `mapv`, `filterv`, `apply`, `select-keys` and
`nexis.string/join` consume their sequence argument (`docs/GC.md`
§11.5), as §3.31's natives do. `reverse` and `butlast` gather the
elements into the vector their list views, `reverse` swapping them in
place; `apply` gathers a lazy seq's there before it copies them out as
the arguments; `join` walks a lazy seq once, writing each element's
text as it goes. Provenance: §11.

Each program binds the pipeline `(map inc (filter even? (map inc
(range n))))` by `let` and hands it to the native (`join` of strings
maps `str` last), n/2 elements; whole process, three interleaved runs
(the `join` rows five), the peak resident set and the median
instructions and cycles, the peak before the change in brackets:

| Program | n | Peak RSS | Instructions | Cycles |
|---|---:|---:|---:|---:|
| `(first (reverse s))` | 3 M | 48.2 MB (112.5) | 779 M | 176 M |
| | 30 M | 435.6 MB (967.7) | 7,953 M | 1,862 M |
| `(count (butlast s))` | 3 M | 48.3 MB (112.5) | 773 M | 180 M |
| | 30 M | 435.7 MB (968.0) | 7,892 M | 1,862 M |
| `(count (mapv inc s))` | 3 M | 48.3 MB (93.9) | 839 M | 204 M |
| | 30 M | 435.9 MB (943.3) | 8,586 M | 1,994 M |
| `(count (filterv odd? s))` | 3 M | 48.3 MB (93.9) | 846 M | 207 M |
| | 30 M | 435.8 MB (943.3) | 8,616 M | 1,978 M |
| `(apply max s)` | 3 M | 72.3 MB (87.1) | 897 M | 218 M |
| | 30 M | 675.7 MB (829.1) | 9,159 M | 2,147 M |
| `(count (select-keys {1 :a 3 :b} s))` | 3 M | 21.7 MB (61.6) | 855 M | 195 M |
| | 30 M | 21.6 MB (587.5) | 8,275 M | 1,835 M |
| `(count (nexis.string/join "," s))`, strings | 3 M | 47.2 MB (135.4) | 1,519 M | 296 M |
| the same over the fixnums | 3 M | 46.7 MB (73.0) | 1,075 M | 229 M |

Over a vector, `reverse` and `butlast` of 3 M elements take 273 M and
259 M instructions (from 461 and 456) and 154 MB (from 203): the
vector their list views is the one they gathered into, where they
copied a buffer into a fresh one. `(reverse (range n))` takes 293 M
instructions at 3 M (its runs of computed elements are copied into the
vector rather than appended to a buffer reserved once). `mapv`,
`filterv` and `join` over a vector, and a loop of one-to-five-element
calls of each native, are unchanged within 0.6%. In the `bench/compare`
language programs every row's median instructions is within 0.4% but
`string-split`, whose `join` of 170,000 strings retires 269 M and
peaks at 33.4 MB, the text's buffer grown as it is written where it
was sized from a first walk.

`zipmap` keeps every value with its key until it builds the map from
all of them at once, and its keys argument holds a chain of its own.
Consuming its values, each rooted in a `Results` as the walk handed it
out, took `(count (zipmap (range n) s))` from 240.6 to 218.4 MB but
raised its instructions from 1,974 to 2,008 M, and over a vector of
values raised its peak from 506.8 to 557.4 MB; `zipmap` walks as it
did.

`vec` of a list that views a whole vector (`sort`'s, `reverse`'s, a
vector's seq) is that vector, without its metadata, where it gathered
the elements into a buffer and built a second vector: the
`bench/compare` `sort` row, whose `(nth (vec sorted) 500000)` takes
one, 958.7 M instructions and 120.1 MB (from 1,044.6 M and 136.5 MB);
`(count (vec s))` and `(count (vec (reverse s)))` of a sorted 3 M,
2,316 M and 445.8 MB (from 2,898 M and 592.5 MB).

### 3.36 A smaller store, Linux x86-64 and Apple M5

Four levers took the §3.11 load (100,000 people of five attributes,
1,000 a transaction) from 144 MB to 51 MB on the Apple M5 and from
136 MB to 52 MB on the Linux host of §3.15, with history whole
(`docs/NEXTOMIC.md` §2): emdb's leaf insert hint (L3), history trees
that hold only retired rows (L1), a binary txlog (L4), and entity and
attribute ids and current values' `t` in as few bytes as they take
(L2). The store is 1.24× Datalevin's 42 MB, which keeps no history,
2.1× Datomic Local's 25 MB and 2.9× Datomic Pro's 18 MB. Provenance:
§11.

Every tree, the stages in commit order, `zig build bench
-Doptimize=fast -- --filter nextomic-store` (each shape's trees in MB
of pages, then the file's allocated MB; the size does not depend on
the machine's load):

| stage | bulk | small transactions | churn | 282-byte strings |
|---|---:|---:|---:|---:|
| v0.1.0, emdb `8e1ed1e` | 129.9 / 143.7 | 39.1 / 43.0 | 89.4 / 101.7 | 78.5 / 84.9 |
| L3: emdb `b3370fb` | 123.8 / 135.3 | 30.0 / 34.6 | 76.1 / 84.9 | 74.8 / 76.5 |
| L1: retired rows alone in history | 66.8 / 76.5 | 16.6 / 17.8 | 72.1 / 84.9 | 46.8 / 51.4 |
| L4: the binary txlog | 61.9 / 68.2 | 15.1 / 17.8 | 67.7 / 76.5 | 33.8 / 43.0 |
| L2: E, A and LEB `t` | 44.2 / 51.4 | 11.6 / 17.8 | 52.9 / 59.8 | 32.0 / 34.6 |

The shapes: bulk is the load above; small transactions are 20,000
one-entity transactions, then 2,000 upserts; churn is 10,000 people
whose card-one attributes all change five times, a tenth retracting a
score in one round and asserting it again in the next; the strings are
20,000 values of 282 bytes, each replaced once. emdb extends a file 8
MiB at a time, so the allocated figure moves in those steps.

The bulk load's trees at the end:

| tree | entries | key B | value B | leaves | fill | MB |
|---|---:|---:|---:|---:|---:|---:|
| `nx/eavt` | 500,267 | 6.85 M | 0.50 M | 856 | 0.88 | 14.0 |
| `nx/aevt` | 500,267 | 6.85 M | 0.50 M | 843 | 0.90 | 13.8 |
| `nx/avet` | 200,231 | 3.16 M | 0.20 M | 494 | 0.66 | 8.1 |
| `nx/vaet` | 100,000 | 0.63 M | 0.10 M | 200 | 0.53 | 3.3 |
| four history trees | 0 | | | | | 0 |
| `nx/txlog` | 103 | 103 | 4.00 M | 300 overflow pages | — | 4.9 |
| all trees | | | | | | 44.2 |

A datom takes 14.7 bytes of key and value in EAVT, 78 bytes of the
four index trees' pages together (AVET and VAET hold some datoms
only), and 8.0 bytes of txlog.

- **L3** needs no Nextomic code: emdb's leaves record their last
  insert (emdb `SPEC.md` INV-S14), so a run its puts make across
  transactions, or between puts elsewhere, splits nine tenths
  (`docs/NEXTOMIC.md` §2.5). It pays most where a transaction writes a
  few keys into each gap: AEVT of the small transactions 0.53 → 0.87
  fill.
- **L1** removes a current fact's latest assertion from history, about
  one row per current fact per index: the bulk load's history trees
  are empty, and a transaction that adds facts writes no history tree.
  A churn store saves little, since its history is mostly retired
  rows: a retraction's two rows land among existing keys, and writing
  the retraction's own row first keeps them from being a run of two,
  which a full leaf splits at (EAVT-h fill 0.47 written in key order,
  0.61 so); past the tree's last key they go in key order and fill to
  0.98. The strings' payloads move from EAVT-h to the current EAVT row
  and are stored once.
- **L4** writes each datom of the txlog in about 8 bytes: an entity
  delta, `a` and `added` in one LEB, the value by its attribute's
  type, a long string as its digest whose payload is the index row's,
  the instant once in the header.
- **L2** shortens every key: a user entity takes four bytes (a header
  and three) where it took six, an attribute one where it took four,
  and the current value's `t` one or two.

Reads. A read probe (`bin/nexis` over the store `nexis-load.nx`
builds, every query run N1 and N2 times, the difference in
instructions retired over N2 − N1, `/usr/bin/time -l`, three
interleaved rounds, medians; the spread below 1%), format 3 against
format 2 with the same code and the same emdb. Churn is that store
after two rounds of 20,000 salary changes:

| query, per run | format 3 | ratio to format 2 |
|---|---:|---:|
| lookup by a unique email | 17.2k | 0.95 |
| three-clause join, 1,000 rows | 6.98 M | 0.99 |
| aggregate over 100,000 people | 290.4 M | 1.01 |
| pull of 1,000 people with a nested ref | 13.06 M | 0.96 |
| the join as of the middle of the load | 4.19 M | 0.74 |
| one entity's history | 15.3k | 0.78 |
| churn: the join, current view | 7.09 M | 1.00 |
| churn: the join as of the first round | 9.21 M | 0.87 |
| churn: salaries by department as of the first round | 8.87 M | 0.86 |
| churn: every salary's history, 180,000 rows | 212.5 M | 0.82 |

On the Linux host the same probe under `perf stat` (user cycles, one
pinned core) gives the pull +4.2% cycles, +1.2% instructions, with
twice as many branch misses as format 2 had, the aggregate +2.4%
cycles and the join +0.2 to +3.7%: an entity's variable-length offset
costs a branch where the fixed field cost none. A time view reads the
current and history trees merged and pays a second seek only where
history holds rows; on an append-mostly store it reads fewer pages
than format 2 did.

`bench/compare` on the Linux host, nexis alone, medians of ten rounds,
two runs: load, default commit 379, 377 ms (from 491, 494); 10k point
lookups 16.0, 15.7 ms; three-clause join 21.4, 22.6 ms; aggregate
34.5, 34.8 ms; pull of 10k entities 12.8, 12.8 ms (4% slower cold,
outside its spread of 12.1–12.7, and 2% warm: the entity decode
above); 1,000 one-datom transactions 11.4, 11.3 ms (from 17.7); 1,000
one-entity transactions 13.8, 14.0 ms (from 27.5); 1,000 upserts 10.2,
10.3 ms (from 14.3); as-of and history query 3.43, 3.42 ms; the store
after the load (`du`) 52 MB (from 136). Beside Datalevin the format-3
store is 52 MB against its 42 MB, and the phases of §3.15 hold their
ratios or improve (load 0.10, one-entity transactions 0.01).

Small transactions (§3.27's probe on the Apple M5, three interleaved
rounds; pages from a build that prints each commit's dirty pages),
format 2 → format 3:

| shape | pages | instructions | μs |
|---|---:|---:|---:|
| new entity, 5 attributes, none unique | 27.1 → 15.0 | 185.5k → 123.7k (−33%) | 17.6 → 10.9 |
| new entity, 5 attributes, one unique | 31.1 → 17.0 | 222.3k → 146.9k (−34%) | 24.5 → 12.8 |
| upsert, 5 attributes, 1 changed | 19.1 → 15.0 | 157.8k → 126.2k (−20%) | 18.8 → 11.9 |
| one datom through a lookup ref | 19.1 → 15.0 | 146.3k → 114.6k (−22%) | 13.2 → 11.3 |
| an entity retracted whole, 5 retractions | 31.1 → 28.1 | 257.7k → 248.2k (−4%) | 28.3 → 24.7 |

A new entity writes no history tree; a retraction writes two rows to
each where format 2 wrote one, and still dirties fewer pages, its keys
shorter and its leaves fuller.

### 3.37 Var calls, Apple M5

What a call of a leaf native or a closure through a Var costs, and
two levers on it, neither kept (§6 "A Var's load run with its call"
and "Calls of one or two arguments in place"). Provenance: §11.

`(nth v i)`, `(count v)` or `(max acc i)` through a Var is a
`var:load-var` of the callee, a `mov:move` or `mov:load-const` of each
argument into a block and `call:call`, which goes on to `callLeaf`:
three or four dispatches. The micro kit (`docs/BENCH.md` §13), five
rounds, instructions an iteration, the median and the range of the
paired rounds; "base" is the tree the levers were measured over, "load
run" the first lever (the load run with its call), "in place" the
second (calls in place, the load run with `call2`):

| Program | Base | Load run | In place |
|---|---:|---:|---:|
| `count` | 58.0 [57.3–58.1] | 58.1 | 57.9 |
| `gcall`, `(f 7)` of a `defn` | 231.1 [231.0–231.5] | 221.4 [221.0–221.6] | 194.0 [193.9–194.1] |
| `leaf`, `(max acc i)` into a `recur` | 300.1 [299.8–300.2] | 289.5 [289.3–289.6] | 284.0 [283.9–284.2] |
| `getnl`, `(get v 3)` | 395.0 [394.6–396.3] | 384.6 [384.6–384.9] | 358.1 [358.0–358.3] |
| `vnth`, `(nth v j)` | 332.0 [331.9–332.3] | 321.2 [321.1–321.4] | 290.0 [289.9–290.3] |
| `leaf1`, `(count v)` | 300.2 [299.9–300.7] | 289.4 [289.3–291.0] | 263.1 [262.6–263.3] |
| `vdestr`, `[x y & more]` of a vector | 1281.6 [1280.6–1287.3] | 1239.0 [1238.3–1239.1] | 1235.9 [1235.4–1236.2] |

Above `count`, the calls in place take `gcall` 21.4% fewer
instructions, `leaf1` and `vnth` 15%, `getnl` 11%, `leaf` 6.6% and
`vdestr` 3.7%; the load run with its call takes 3.2–5.7% off each. Whole
process, three interleaved runs: `destructure` 3,326.8 → 3,248.1 M
instructions (−2.4%), `vector-conj-nth` −0.7%, `pipeline` and `fib`
unchanged; every other program is within its range and every peak
resident set the same.

The calls in place take dispatches an iteration from 6 to 4 in
`gcall`, 5 to 3 in `leaf`, 7 to 4 in `getnl` and `vnth`, 6 to 4 in
`leaf1` and 22 to 18 in `vdestr`, whose two `nth` calls take three
arguments; the load run with its call takes one from each.

What the rows say. A dispatch costs about ten instructions, the
fetch, the table load and the branch; the rest of what `lv` and `mv`
add to `count` is the loop's own instructions that the step no longer
fuses (§3.26). An instruction-by-instruction trace of one `leaf1`
iteration under `lldb` counts 297 instructions before and 263 after:
the native, `count` of a vector, is 61 of them (`fnCountLeaf` and
`fnCount`); the call around it 107, of which the in-place call's fast
handler is 25, its out-of-line part's frame, arity tests and second
read of the callee 55, and the safe point and the next fetch the
rest. `callLeaf` behind `call:call` costs about the same; what the
calls in place remove is the moves, not the call.

### 3.38 x86-64 handlers without register saves, Linux x86-64 and Apple M5

Every dispatch handler and out-of-line part returns a status word,
`VM.Status`, not `VmError!void`, and on x86-64 takes the
`x86_64_preserve_none` calling convention (`docs/VM.md` §8), under
which no general register but rsp and rbp is the callee's to save.
Under System V's, whose nine scratch registers include the handler's
four arguments, a handler that kept more live values saved callee-saved
registers with `push` at its entry and `pop` before its tail call;
under `preserve_none` it saves nothing for the handler before it, and
an out-of-line part keeps its values across a native's call in the
registers System V has the native save. Zig allows an error union as
the return type of no calling convention but `.auto`, hence the status
word. Provenance: §11.

The x86-64 release build's static sizes (`zig build codegen`),
instructions and registers saved, System V → `preserve_none`:

| Function | before | after |
|---|---:|---:|
| `fastCall` | 142, 6 | 110, 0 |
| `fastCallSelf` | 106, 4 | 94, 0 |
| `fastCmp`, any operand kind | 150, 3 | 141, 0 |
| `fastMath`, any operand kind | 127–150, 1–2 | 124–142, 0 |
| `fastMathQuick`, `idiv` and `mod` | 54–70, 0–2 | 52–62, 0 |
| `fastStep`, a slot limit | 72, 1 | 69, 0 |
| `callLeaf`, out of line | 111, 4 | 77, 0 |
| `callLookup`, out of line | 111, 5 | 88, 0 |
| `lookupPart`, out of line | 156, 5 | 135, 0 |
| `callBuffered`, out of line | 195, 6 | 187, 1 |

Every other fast handler saved nothing and is the same size. No
handler saves rbp, the one register the convention leaves the callee
to save: `fastCall`, the largest, fits in the other fourteen. On arm64,
whose handlers keep `.auto`, every fast handler and out-of-line part is
the same size instruction for instruction; the status word moves only
the general handlers' register allocation (`opCtrl` 185 → 197
instructions, the others within 3), and the micro kit on the M5 retires
the same instructions.

Linux x86-64, the micro kit (`docs/BENCH.md` §13) with `--counter perf
--pin 2`, two runs of ten interleaved rounds, holding the host's
benchmark lease alone; per unit, the median of the twenty rounds,
before → after:

| Program | instructions | cycles | blocked loads |
|---|---:|---:|---:|
| `count` | 65.0 → 63.0 | 10.4 [10.3–10.6] (−1.6%) | 0 |
| `fib`, a call | 211.5 → 203.5 | 42.6 [42.5–43.6] (−6.4%) | 0 |
| `gcall` | 263.0 → 251.0 | 49.6 [49.4–50.1] (−4.9%) | 0 |
| `leaf` | 357.0 → 325.0 | 74.8 [74.0–75.7] (−2.0%) | 1.032 |
| `getnl` | 426.0 → 396.0 | 96.7 [95.9–97.5] (+1.1%) | 1.996 |
| `cbsum` | 106.6 → 106.6 | 35.4 [34.1–39.8] (−3.2%) | 0 |
| `cb` | 117.5 → 117.7 | 42.1 [39.8–44.2] (−2.2%) | 0 |
| `lazy` | 210.8 → 211.2 | 72.7 [71.7–74.2] (−1.9%) | 0.241 |

`fib` and `gcall` ran at least 3% fewer cycles in every one of the
twenty rounds' pairs. The indirect-branch mispredicts are the same:
0.028 a `fib` call, none on the others.

The `bench/compare` language programs on the same host, ten rounds,
medians, before → after:

| Row | phase | instructions | cycles |
|---|---:|---:|---:|
| `fib` 30 | 26.4 → 24.4 ms | 572.7 → 551.1 M | 127.6 → 117.8 M |
| destructuring loop | 208.1 → 202.4 ms | 3,625.0 → 3,401.0 M | 975.8 → 947.6 M |
| pipeline | 55.0 → 45.4 ms | 2,207.4 → 2,134.9 M | 707.5 → 649.2 M |
| vector `conj` and `nth` | 60.9 → 60.7 ms | 792.1 → 762.1 M | 261.9 → 262.4 M |

Against babashka (`run.clj`, two passes): `fib` 25.8, 26.3 ms (0.16,
0.17 of its time), the destructuring loop 205, 204 ms (0.48), the
pipeline 44.9, 45.2 ms (0.92, 0.99, from 1.17, 1.09), vectors 61.2,
62.8 ms (0.51, 0.52); every resident set unchanged.

What the rows say:

- The instructions fall by exactly the saves: 8 a `fib` call
  (`fastCallSelf`'s four pairs), 12 a closure call (`fastCall`'s six;
  rbp is not among them, so the whole 12 goes), 2 an iteration of the
  counting loop (`fastStep`'s pair), 32 a leaf call and 30 a native
  call (`fastCall`'s pairs on its way out of line, `callLeaf`'s or
  `callBuffered`'s, and the moves that copied the arguments into
  callee-saved registers before the native's call).
- The cycles fall less than the instructions on the native paths: each
  leaf call still waits on a load the store before it cannot forward
  (`callLeaf`'s 16-byte read of the native's result, about 12 cycles;
  §3.40 "A width-consistent native boundary"), and `getnl` blocks twice
  an iteration, so its 7% fewer instructions run in 1% more cycles. The
  destructuring loop, five leaf calls and a closure call an iteration,
  retires 6.2% fewer instructions and runs 2.6% faster, its blocked
  loads up 7%.
- `fib` runs in 26 ms, 5.6× warm JVM Clojure's 4.68 ms (§3.15), from
  6.0×; the destructuring loop 5.3×, from 5.5×.
- The chain's entries, `drive` and a `Callback`'s call, save what they
  keep across the chain once a pass, under any convention: `cbsum`, `cb`
  and `lazy` run the same instructions and no more cycles.
- Debug x86-64 builds tail-call through LLVM's `musttail` under the
  convention: the gate, its `deep-calls` and `deep-recursion` CLI
  goldens among it, passes on the Linux host.

### 3.39 Durable commits, Linux x86-64 and Apple M5

What a durable commit costs and where its time goes, on the Linux host
of §3.15 (ext4 on NVMe), against Datalevin 1.1's commit, which syncs.
A probe program commits 300 transactions of one shape through a
connection opened `{:durability :durable}` and times each; its
Datalevin twin commits the same transactions in Datalevin's default
mode; a `db/*` probe puts one value under one key per commit, the
smallest commit nexis makes. Both databases hold §3.15's load of
100,000 people. The device's flush on this host moves, over tens of
seconds and from activity outside the run, between about 0.9 ms and 2
ms or more; the table takes the rounds, from five runs, in which the
device stayed in its fast state for every run compared (seven for
`db/*`, six for the datom and the entity, five for the upsert), the
probes alternating within each round: the median, the range in
brackets, and the median of the rounds' ratios. The `:commit` column is
the same transactions with `{:durability :commit}`, a thousand of each.
One ReleaseFast build. Provenance: §11.

| Commit | pages | `:commit` | durable | Datalevin | ÷ Datalevin |
|---|---:|---:|---:|---:|---:|
| `db/*`, 8 bytes | 3 | 1.4 μs | 1.82 ms [1.81–1.89] | | |
| `db/*`, 64 KiB | 8 | 10 μs | 1.96 ms [1.93–1.99] | | |
| one datom by lookup ref, a salary replaced | 14 | 13 μs | 2.22 ms [2.15–2.32] | 1.98 ms [1.97–2.03] | 1.12 [1.06–1.18] |
| one new entity, five attributes | 20 | 18 μs | 2.33 ms [2.27–2.43] | 2.02 ms [2.00–2.17] | 1.16 [1.05–1.21] |
| upsert by the unique email, one of five changed | 14 | 13 μs | 2.23 ms [2.19–2.29] | 2.01 ms [1.99–2.08] | 1.10 [1.08–1.15] |

*Pages* are the 16 KiB pages a commit writes, counted from emdb's
dirty-page table as the commit seals them. The one-datom transaction's
fourteen:

| Tree | pages | What |
|---|---:|---|
| EAVT | 4 | the person's leaf and the transaction entity's, and their branches |
| AEVT | 3 | the salary's leaf and `:db/txInstant`'s, and their branch |
| AVET | 2 | `:db/txInstant`, which Datomic indexes too |
| EAVT-h, AEVT-h | 2 | the retired salary and its retraction |
| `nx/sys` | 1 | `t`, the attribute counts, the full-text stamp |
| `nx/txlog` | 1 | the transaction's entry |
| emdb's main tree and free list | 1 | the records of the trees that changed |

What the rows say:

- nexis does nothing at a durable commit beyond emdb's minimum. Under
  `strace -f` a Nextomic commit is emdb's two `fdatasync` and no other
  system call: no further sync or write transaction. Its one read
  transaction, the report's, which resolves the tx-data's idents and
  is kept as the held snapshot (`docs/DB.md` §3.4), is about 3% of a
  transaction's instructions (§3.27) and calls nothing in the kernel.
  emdb's durable commit is level with LMDB's (515 against 521 commits
  a second on ext4, the engine owner's run; the second flush costs
  about 886 μs in any form), and the smallest one through nexis, three
  pages, takes 1.82 ms here.
- The gap is the pages. Each 16 KiB page past the smallest commit costs
  about 25 μs written contiguously (the 64 KiB value's five overflow
  pages) and about 35 μs spread over the trees (the datom's eleven): the
  kernel writes it back, the device takes it before the flush, and the
  next commit's first write to each of its four 4 KiB pages faults, the
  flush having cleaned them. A durable datom commit takes 52 page
  faults and 172 μs on the CPU (`perf stat`), the smallest commit 7
  faults and 80 μs. Datalevin writes 13 pages of 4 KiB with `pwrite`
  and `writev`, 54 KB, then its flush and its meta page through an
  `O_DSYNC` descriptor: a quarter of Nextomic's 224 KiB.
- Six or seven of the datom's fourteen pages hold what Datalevin does
  not write: the transaction entity's `:db/txInstant` datom in EAVT,
  AEVT and AVET (4 to 5 pages; Datalevin, as DataScript, records no
  transaction entity) and the history rows of the replaced salary (2).
  At 35 μs a page they are the 0.24 ms between the two systems. The
  levers are the format's, measured and not built (§6 "Fewer pages per
  durable commit").

**What each default costs a program.** The whole process's work, start
to `release`, of a program that creates a store, transacts a
two-attribute schema and N one-entity transactions; `:commit` syncs
once, at `release`. The Linux figures are the fast state's (five runs
each); the M5's are APFS with `F_FULLFSYNC`, shared with concurrent
sessions (three runs each). §3.15's load (100 transactions of 1,000
people) is the `bench/compare` phase (Linux: the median of ten rounds,
and the four durable rounds in the fast state; the M5: two runs).

| Program | Linux `:commit` | Linux durable | M5 `:commit` | M5 durable |
|---|---:|---:|---:|---:|
| one transaction | 9.7–11.9 ms | 16.9–23.0 ms | 10.4–13.3 ms | 30.6–32.9 ms |
| 1,000 transactions | 16.7–21.6 ms | 2.13–2.16 s | 16.5–22.9 ms | 5.96–7.42 s |
| §3.15's load | 382 ms | 1.02–1.09 s | 318–336 ms | 1.33–2.18 s |

A program of a few transactions pays a few milliseconds for durable
commits, nexis's default; one of many small transactions pays a device
flush for each, 2 ms here and 6–7 ms on the M5, which batching them
into fewer transactions, or `:commit`, avoids (`docs/DB.md` §3.3 "Why
durable is the default").
### 3.40 A width-consistent native boundary, Linux x86-64 and Apple M5

On x86-64 a load takes its data from a store still in flight only when
that one store covers it; any other waits for the stores to reach the
cache, about a dozen cycles. Compiled Zig reads and copies a whole
`Value` with one 16-byte load, and returns a `VmError!Value` through
memory in narrow stores, so a value that crossed between the handlers,
which store and read two 8-byte words, and a native stalled at the
crossing: `callLeaf`'s 16-byte read of what the native had stored as
two words and a 2-byte error, a native's 16-byte read of an argument a
move had just stored as two words, a map's constructor reading a key
and value as one 32-byte entry of what the gather had stored a value
at a time. The boundary keeps the widths consistent (`docs/VM.md` §8):
on x86-64 the moves, constant, cell and upvalue loads that fill a
call's block, and a call's result, are stored as one 16-byte store
(`VM.storeWide`); a native's result is read a word at a time where the
call stores it (`call:call`, the buffered and the general call,
`call:lookup`, `coll:*`); the arguments a buffered or general call and
a collection's construction copy off the stack go a value at a time, a
map's pairs as one 32-byte entry (`VM.copyRun`, `VM.copyEntries`); and
`max` and `min` read their winner a word at a time, so their result is
never assembled in a temporary and copied out wider. A Var's value (a
callee), a return and a callback's window stay two 8-byte stores: a
handler's 8-byte loads take their data a cycle later from a 16-byte
store, which a value on the dispatch's chain pays (stored whole, a
closure call ran 49.6 → 50.6 cycles and `cb` 41.8 → 44.4). arm64 keeps
its stores and copies. Provenance: §11.

Linux x86-64, the micro kit (`docs/BENCH.md` §13) with `--counter perf
--pin 2`, two runs of ten interleaved rounds, each in its own hold of
the host's benchmark lease; per unit, the median of the twenty rounds,
before → after:

| Program | instructions | cycles | blocked loads |
|---|---:|---:|---:|
| `count` | 63.0 → 63.0 | 10.4 [10.3–10.5] (+0.1%) | 0 |
| `fib`, a call | 203.5 → 203.5 | 42.6 [41.9–43.6] (−0.2%) | 0 |
| `gcall` | 251.0 → 251.0 | 49.5 [49.3–49.9] (−0.2%) | 0 |
| `leaf` | 325.0 → 337.0 | 64.5 [64.0–65.2] (−14.4%) | 1.034 → 0 |
| `getnl` | 396.0 → 402.0 | 86.5 [85.8–87.0] (−10.6%) | 1.991 → 0 |
| `vnth` | 335.0 → 341.0 | 66.0 [65.6–66.9] (−10.1%) | 0.499 → 0 |
| `leaf1` | 303.0 → 309.0 | 73.2 [72.9–73.5] (−17.7%) | 1.998 → 1.008 |
| `vdestr` | 1293.8 → 1317.8 | 338.1 [336.6–341.3] (−4.4%) | 4.221 → 1.946 |
| `cbsum` − `cbbase` | 71.5 → 71.5 | 15.7 (−3.3%) | 0 |
| `cb` − `cbbase` | 82.8 → 82.8 | 21.9 (−0.6%) | 0 |
| `lazy` − `cbbase` | 176.0 → 176.0 | 54.5 (+1.3%) | 0.230 → 0.225 |

The `bench/compare` language programs on the same host, ten rounds,
medians, before → after:

| Row | phase | instructions | cycles | blocked loads |
|---|---:|---:|---:|---:|
| destructuring loop | 199.7 → 186.5 ms | 3,401.0 → 3,481.0 M | 945.6 → 876.2 M (−7.3%) | 17.42 → 5.36 M |
| vector `conj` and `nth` | 60.0 → 57.0 ms | 762.1 → 768.1 M | 261.0 → 245.6 M (−5.9%) | 3.19 → 2.19 M |
| pipeline | 45.9 → 46.4 ms | 2,135.3 → 2,167.3 M | 656.7 → 646.0 M (−1.6%) | 14.76 → 8.74 M |
| `fib` 30 | 24.3 → 24.6 ms | 551.1 → 551.1 M | 118.2 → 119.4 M | 0.021 → 0.021 M |

Against babashka (`run.clj`, two passes): the destructuring loop 192,
190 ms (0.44, from 0.48), vectors 59.4, 58.8 ms (0.49, 0.48), the
pipeline 46.0, 46.2 ms (1.02). On the Apple M5 every micro-kit program
retires the same instructions within 0.2 a unit but `leaf`, 300.0 →
297.0 (`numExtremum`'s winner read in place), and its cycles stay
within their ranges.

What the rows say:

- A leaf call no longer waits on its result: `leaf` runs 14% fewer
  cycles, `getnl` and `vnth` about 10%, `leaf1` 18%, though each
  retires 6–12 more instructions (the word-wise reads, and the 16-byte
  stores built from two words).
- The destructuring loop blocks 5.4 loads an iteration where it blocked
  17.4, and runs 7.3% fewer cycles: 186.5 ms, 0.44 of babashka's time.
- What blocked after this change is inside natives (§3.41 removes it):
  a `VmError!Value` a native assembles in a temporary of narrow stores
  (two words and the 2-byte error) and copies to its caller with an
  8-byte and a 16-byte load, where its returns merge (`fnCount`,
  `fnNth`, `fnNthrest`, `fnForce`; `leaf1`'s remaining block is
  `fnCount`'s), and `champ.mapFromEntries`' hashed-entry array, written
  in 4-byte fields and read 8 bytes at a time (§6 "A native's result
  assembled in a temporary").
- The pipeline's run.clj phase is 1 ms over the earlier build's in both
  passes, within its range, while its cycles under `perf stat` fall
  1.6%: its calls are of closures from natives, whose windows stay word
  stores; it retires 32 M more instructions, the copies a value at a
  time of its non-leaf natives' arguments.

### 3.41 Natives that return in place, Linux x86-64 and Apple M5

A native returns its `VmError!Value` through memory. Compiled Zig
stores a `return` of a value it holds, or of an error, where the
caller reads it: two 8-byte words or one 16-byte store, and the 2-byte
error. A result merged from an `if`, a `switch`, an `orelse` or a
labeled block, or returned from a call of another function's body, it
assembles in a temporary of those stores and copies on with an 8-byte
load of the error's word and a 16-byte load of the value, neither of
which the x86-64 store buffer forwards: each waits for the stores to
reach the cache (§3.40). So `count`, `nth` and `nthnext`, the leaves a
destructuring form calls, return each result by a statement of its
own; the leaf and the general native of `count` and of `nthnext` are
one body each, generated for both, not a leaf that calls the general
native and copies its result on; and `nthnext` of nil, a list or a
vector returns the rest itself rather than `seq` of `nthrest`
(`docs/VM.md` §8). A map literal's bulk build sorts its entries by one
64-bit key, the bit-reversed hash above the input position, stored and
compared whole, where it stored two 4-byte fields and read them as one
word (`docs/CHAMP.md` §8.1). Provenance: §11.

Linux x86-64, the micro kit (`docs/BENCH.md` §13) with `--counter perf
--pin 2`, two runs of ten interleaved rounds, each in its own hold of
the host's benchmark lease; per unit, the median of the twenty rounds,
before → after:

| Program | instructions | cycles | blocked loads |
|---|---:|---:|---:|
| `count`, `fib`, `gcall`, `leaf`, `getnl` | the same | within 0.7% | 0 |
| `vnth` | 341.0 → 340.0 | 65.6 [65.0–66.0] (−4.4%) | 0 |
| `leaf1` | 309.0 → 270.0 | 53.8 [53.5–54.1] (−27.2%) | 1.006 → 0 |
| `vdestr` | 1317.9 → 1198.9 | 255.2 [253.3–258.0] (−26.2%) | 1.913 → 0.001 |
| `cbsum`, `cb`, `lazy` less `cbbase` | the same | within 1.6% | 0 |

The `bench/compare` language programs on the same host, ten rounds,
medians, before → after:

| Row | phase | instructions | cycles | blocked loads |
|---|---:|---:|---:|---:|
| destructuring loop | 199.7 → 176.1 ms | 3,481.7 → 3,364.7 M | 936.2 → 820.5 M (−12.4%) | 5.21 → 0.03 M |
| vector `conj` and `nth` | 57.3 → 56.9 ms | 768.5 → 767.5 M | 245.2 → 243.7 M (−0.6%) | 2.18 → 2.16 M |
| pipeline | 43.8 → 43.3 ms | 2,167.5 → 2,172.5 M | 634.9 → 631.6 M (−0.5%) | 8.78 → 6.96 M |
| map build and read | 879.1 → 882.5 ms | 3,471.3 → 3,470.3 M | 4,160.7 → 4,157.7 M (−0.1%) | 2.90 → 2.93 M |
| `fib` 30 | 24.3 → 24.3 ms | 551.5 → 551.5 M | 118.2 → 117.6 M | 0.02 → 0.02 M |

The natives alone, without the sort key (four rounds of the
destructuring loop): 942 → 848 M cycles, 5.21 → 3.99 M blocked loads;
the sort key takes it to 819 M and 0.03 M. Against babashka
(`run.clj`, two passes): the destructuring loop 177 ms (0.41, from
0.47), vectors 58.2, 57.9 ms (0.48), the pipeline 43.3, 43.4 ms (0.93,
0.87), the map build 884, 881 ms (0.61). On the Apple M5 `leaf1`
retires 262.0 instructions a unit (from 300.0), `vdestr` 1,164.3
(from 1,281.3) and `vnth` 328.0 (from 332.0).

What the rows say:

- A leaf that returns in place runs no blocked load: `leaf1` (a
  `count` of a vector) runs 27% fewer cycles and `vdestr` (two `nth`,
  an `nthnext` and a `count`) 26%. The generated leaf of `count` drops
  what only the general native does, its frame and the entity and lazy
  cases, so it also retires 39 fewer instructions on x86-64 and 38 on
  arm64.
- The destructuring loop runs 12.4% fewer cycles: 176–177 ms, 0.41 of
  babashka's time, its blocked loads 5.2 M → 0.03 M.
- What still blocks in these rows is elsewhere: the pipeline's 7 M are
  in its setup, the sort of a three-entry map literal's entries
  (`std.mem.sortUnstable` moves a 40-byte entry in pieces its next
  comparison reads whole); the map build's 2.9 M in `assoc`
  (`assocOne`, `champ.mapAssoc`); the vectors' 2.2 M in `vector.conj`
  and the heap's allocation (§6 "A native's result assembled in a
  temporary").
- The pipeline's and the map build's run.clv phases are within 1 ms and
  2% of before, inside their ranges, while their cycles under `perf
  stat` are level.

### 3.42 Leaf bodies that take a vector first, Linux x86-64 and Apple M5

A call of `get`, `nth` or `count` through a Var is a leaf call
(`docs/VM.md` §6), whose cost past the call is the native's body. `get`
is one body for the leaf and the general native, each result returned
by a statement of its own; `count` returns a count per kind; and all
three take their common receiver, a vector, before the switch over
every kind, by a test of the whole tag word every vector value carries,
which the optimizer keeps apart from the switch where a test of the
kind joins its table (`docs/VM.md` §8). Provenance: §11.

Apple M5, the micro kit (`docs/BENCH.md` §13), five interleaved rounds
under `tools/heavy` (1 core), instructions and cycles an iteration, the
median with the range, before → after:

| Program | Instructions | Δ | Cycles |
|---|---:|---:|---:|
| `getnl`, `(get v 3)` | 395.0 → 295.0 [295.0–295.3] | −25.3% | 50.0 → 38.0 |
| `vnth`, `(nth v j)` | 328.0 → 297.1 [296.9–297.2] | −9.4% | 50.3 → 42.9 |
| `leaf1`, `(count v)` | 262.0 → 253.0 [252.9–253.2] | −3.4% | 32.8 → 31.7 |
| `vdestr` | 1,164.3 → 1,103.4 | −5.2% | 145.2 → 142.4 |
| `casek`, a `case` over `(:shape m)` | 724.1 → 655.0 | −9.5% | 101.8 → 91.6 |
| `mcall`, a multimethod on `:shape` | 1,235.1 → 1,122.1 | −9.1% | 187.3 → 174.3 |

Every other program retires the same instructions within 0.5 a unit and
every peak resident set is the same.

Linux x86-64, the micro kit with `--counter perf --pin 2`, five
interleaved rounds, per unit, before → after:

| Program | Instructions | Cycles | Δ cycles |
|---|---:|---:|---:|
| `getnl` | 400.0 → 304.0 | 60.1 [59.4–61.5] | −32.2% |
| `vnth` | 338.0 → 313.0 | 60.9 [60.2–61.0] | −8.3% |
| `leaf1` | 268.0 → 258.0 | 53.0 [51.1–54.1] | −3.1% |
| `vdestr` | 1,190.9 → 1,135.9 | 242.0 [238.7–251.2] | −5.1% |
| `casek` | 776.0 → 707.0 | 154.8 [151.4–155.3] | −11.1% |
| `mcall` | 1,335.0 → 1,232.0 | 320.3 [319.2–321.5] | −11.5% |

The `bench/compare` language programs, whole process, the builds
interleaved, medians (Linux: `taskset -c 2`, `perf stat`, seven rounds;
M5: `/usr/bin/time -l`, five rounds under `tools/heavy`), instructions
before → after: destructuring loop −1.8% (Linux, 3,038.7 M) and −2.0%
(M5, 2,942.5 M), vector `conj` and `nth` −3.3% and −3.9%, map build
and read −2.0% and −2.1%, map through transients −4.0% and −3.9%; the
pipeline, `fib`, loop, `frequencies`/`group-by`, string split and
`sort` the same within 0.3%. `run.clj` on the Linux host: the
destructuring loop 183 ms against 182, vectors 58.2 against 62.2, the
pipeline 45.7 against 49.8, the map build 980 against 990.

What the rows say:

- `get` of a vector by an index in range returns the element in place
  with no second call: a quarter of `getnl`'s instructions and a third
  of its cycles on x86-64. A map's lookup by a keyword returns from the
  same body (`casek`, `mcall`, 9–12%).
- `nth` reaches a vector's element before its switch: `vnth` 8–9%,
  `vdestr` 5%.
- `count`'s vector test runs before its switch, but its vector path
  keeps the stack frame its other kinds need, on both hosts: `leaf1`
  3%. A frameless path cost more than it saved (§6 "A leaf's common
  case without a frame").
- Two rows' cycles move with the code's placement alone. The
  destructuring loop calls no `get` (a `-Dopcodes=true` build: per
  iteration two `call:lookup`, two `nth`, a `count` and an `nthnext`),
  yet a build with only the `get` change retires its instructions
  exactly (3,093.7 M) and runs 6% more cycles, its memory-ordering
  machine clears 0.35 → 0.51 M: the row's hot code (`opColl`,
  `champ.fromSlice`, `Heap.alloc`, `callLeaf`) sits 0x1c0 bytes later in
  that build. A build with only the `nth` change runs it 3% faster.
  `run.clj`, over twelve CPUs, has it level. On the M5 `sort`, one call
  of the `sort` native whose code the change does not touch, retires
  the same instructions and runs 7.7% more cycles; on the Linux host it
  is level.

## 6. Levers and dead ends

Each lever is a measured change: a before/after from `zig build bench`
(or a §3.9-style wall-time pair) or it does not land.

**Rows that do not exist.**

- A JVM Clojure column on the Apple host beside §3.11's babashka one,
  and BENCH.md §5's `criterium` comparison with its arithmetic tiers
  anywhere; §3.15 runs the shared programs on the Linux host.
- Garbage-collection rows: steady-state allocation pressure, pause
  times.
- Allocated bytes for a fixed workload (scorecard #1); §3.11 has peak
  RSS per workload.
- A cold-cache random-access `nth` row beside §3.4's sequential one.
- `nexis.simd` and typed-vector rows (scorecard #17).
- Reruns: §3.1–§3.6 on the machine of §3.7–§3.8, with the emdb
  revision, to settle §3.6's 17×.

**Levers not built.**

- **Batched commits** (`docs/DB.md` §3.3 "No batching"): consecutive
  auto-transaction writes joined into one open emdb write transaction
  would save part of a `:commit` transaction's cost, about 18 μs in
  all (§3.11), at the price of holding the writer between natives. A `:durable` commit's two device flushes are the other
  cost left; group commit under one flush would divide it.
- **Fewer pages per durable commit** (§3 "Durable commits"): a
  durable commit pays about 35 μs for each 16 KiB page it writes past
  emdb's smallest, and a one-datom transaction writes 14. Every lever
  left changes the store's format (`docs/NEXTOMIC.md` §2):
  - The transaction entity's `:db/txInstant` datom takes 4 to 5 of
    the 14 pages, in EAVT, AEVT and AVET, as Datomic keeps it. Read
    from the txlog and merged into scans of those indexes instead, it
    would cost every query and pull that touches transaction
    entities a second source; about 0.15 ms a durable commit.
  - The history rows of a retraction take 2, the price of the time
    views.
  - A 4 KiB page would write a quarter of the bytes for the pages a
    transaction dirties, with deeper trees and a quarter of the key
    bound (`docs/NEXTOMIC.md` §2); the page size is fixed for a
    file's life (`docs/DB.md` §3).
- **Store size** (§3.36: 51 MB on the M5, 52 MB on Linux; 1.24×
  Datalevin, which keeps no history, 2.1× Datomic Local and 2.9×
  Datomic Pro). Four levers are pulled: emdb's insert hint, history
  trees that hold retired rows alone, a binary txlog, and entity,
  attribute and `t` in as few bytes as they take. What remains:
  - Datomic's lead is its block-compressed index segments, about 8
    bytes a datom an index. Compressed or prefix-coded leaves would
    break byte keys in index order (`docs/NEXTOMIC.md` §1), make every
    insert a rewrite of its block, and repeat what emdb measured and
    declined (`docs/NEXTOMIC-EMDB.md` §5); refused.
  - AVET's unique strings and VAET's referrers land at random and fill
    about two thirds of their leaves (§3.36's table); no write order
    fills a random gap.
  - A churn store's history is its retired rows, which L1 does not
    shorten: `:db/noHistory`, Datomic's flag that keeps an attribute's
    retired rows out of history, would, at the price of what its time
    views show. Deferred until a workload asks for it.
  - Dropping the value's type tag (the attribute fixes it, −1 byte an
    entry) or `t` from AEVT, AVET and VAET values (−1 to −2 bytes, at
    an EAVT read per `?tx` binding and per row of a time view's merge)
    were weighed and declined; batching transactions is refused
    (`docs/DB.md` §3.3); a `compact!` would free pages but cannot
    shrink a file without an emdb truncate.
  - Scans pay for the variable-length entity: a pull of 10k entities
    is 4% slower cold on Linux (§3.36), its branch on the offset's
    length mispredicting where the fixed field had none.
- **The collector's trigger.** A cycle is due once the heap has
  allocated its live size again (100 %) or 16 MiB. A build that grows
  a large live set is marked at each doubling, about twice its final
  size in all; the pipeline's setup runs four cycles (§3.14) and its
  timed phase none. A lower growth brings a cycle into that phase and
  trades time for resident memory, a higher one or a higher floor
  changes neither (§3.14's trigger table); the remaining measurement
  is a program whose live set stays flat while it allocates.

- **Generational collection**: a nursery and write barriers, so
  short-lived path copies cost O(survivors) (`docs/GC.md` §1).
- **Inline caches at call sites**: a call through a Var is a
  `var:load-var` and a `call:call`, each reading its operands with no
  kind to decode; a cache must still see the Var's latest root (PLAN
  §23 #20). A version stamp on the Var checked at each call site is
  rejected: reading the Var is already two flag loads and two word
  loads, about what a stamp's test costs; the stamp pays only by also
  caching the callee's kind, leaf flag and arity verdict, 8–12
  instructions of a leaf call's 107 (§3.37); it needs state per call
  site that verified, immutable bytecode and the shared stdlib image
  do not have, so a side table; and every write of a Var must bump
  it (`var:store-var`, `alter-var-root` and `with-redefs`, a binding's
  push and pop, `var-set`, `intern`), where one missed write silently
  breaks #20.
- **Comptime specialization** beyond CHAMP's inline immediate hash:
  `(reduce + xs)` over fixnums, `equal` by kind pair.
- **A smaller heap header** for small objects.
- **A single-key read path for durable refs** that skips the general
  transaction scaffolding.
- **Forwarding single-use `let` bindings into a call block**: `(let [x
  (f)] (g x))` computes `x` into its slot and moves it into `g`'s
  block; computing it into the block directly saves the move for each
  binding used once, as an argument, by the body's call.
- **A native's result assembled in a temporary**: on x86-64 a native
  whose returns merge builds its `VmError!Value` in a temporary of
  narrow stores (two 8-byte words and the 2-byte error) and copies it
  to its caller's with an 8-byte load of the error's word and a
  16-byte load of the value, both of which wait for the cache; so does
  a function that returns another's result. `count`, `nth` and
  `nthnext` return in place (§3.41), which leaves the destructuring
  loop 0.03 M blocked loads. What blocks in the other rows: a sort of
  a map literal's entries by `std.mem.sortUnstable`, which moves a
  40-byte entry in pieces its next comparison reads whole (6.7
  blocked loads a three-entry literal; the pipeline's setup, 7 M);
  `assoc` into a map (`assocOne`, `champ.mapAssoc`; the map build's
  2.9 M); `vector.conj` and the heap's allocation (vectors, 2.2 M).
  The two ways around the sort measured so far cost more than they
  saved (below, *A map literal's sort*).
- **A compare-and-branch instruction**: an `if` on `(< i n)` is
  `cmp:lt` into a slot and `jump:if-false` on it, which the dispatch
  runs as one (`docs/VM.md` §8, §3.12). One encoded instruction would
  also drop the slot write and a fetch, but two operands and a jump
  target do not fit it (VM.md §3), so it needs the encoding's
  amendment.

**Levers pulled.** Each is measured in the §3 row it names.

- *Leaf bodies that take a vector first* (§3.42, `docs/VM.md` §8):
  `get` is one body for the leaf and the general native; `count`, `nth`
  and `get` take a vector by its whole tag word before the switch over
  every kind.
- *Natives that return in place* (§3.41, `docs/VM.md` §8): `count`,
  `nth` and `nthnext` return each result by a statement of its own, and
  a map literal's bulk build sorts on one 64-bit key.
- *A width-consistent native boundary* (§3.40, `docs/VM.md` §8): on
  x86-64 the values a native may read whole are stored as one 16-byte
  store, a native's result is read a word at a time, argument runs are
  copied a value at a time and a map's pairs as 32-byte entries.
- *`vec` of a vector's view* (§3.35): `(vec s)` of a list that views a
  vector from its first element is that vector, without its metadata.
- *x86-64 handlers without register saves* (§3.38, `docs/VM.md` §8):
  every handler returns a status word and, on x86-64, takes the
  `preserve_none` convention, so no fast handler saves a register.
- *`sort`'s buffers* (§3.34): `sort` and `sort-by` sort the elements in
  the list they gather them into, each merge through a scratch array of
  half the elements; 80 → 24 MB outside the heap for a million ints.
- *Closures called from natives* (§3.33, `docs/VM.md` §6): a
  `Callback`'s arguments and result move as words, and `reduce`,
  `mapv`, `filterv` and the lazy `map`, `filter` and `remove` make a
  run's calls in one pass of the chain.
- *Sort keys compared in registers* (§3.32): fixnum keys compared in
  place, any other pair's `OrderError!Order` read as it is.
- *Trees opened on first use* (`docs/NEXTOMIC.md` §2): a transaction
  reads the records of the trees it touches, not all twelve; small
  transactions 5.2–7.7% fewer instructions (§3.27).
- *Quickening* (`docs/VM.md` §10.10, §3.25): the hot opcodes
  specialized to their operands' kinds when a routine is finished.
- *The counting-loop step* (`docs/VM.md` §10.10, §3.26): the
  `math:add.sc` before a loop's repeated test is quickened with the
  comparison and jump after it and runs the three as one dispatch. As an
  instruction of its own it would need PLAN §23 #21 amended (its target
  does not fit beside two operands); as a quickened variant it changes
  no encoding, verifier rule for jumps or jump-patching site. The opcode
  histograms (`-Dopcodes=true`) of the ten `bench/compare` language
  programs find the pair in two: 1.0 M of `loop`'s 5.0 M dispatches and
  1.0 M of the destructuring loop's 43.0 M, and in none of the other
  eight, the stdlib's own loops included.
- *The stdlib image* (`docs/STDLIB.md` §1, §3.18): the build boots the
  embedded sources once and every binary loads what they left.
- *Commit without a sync* (`:commit`, `docs/DB.md` §3.3), the explicit
  fast mode: §3.11's 1,000 default-commit transactions took 3.42 s with
  a sync on each and 17.7 ms without; `db_put_commit_scalar` 6.00 ms →
  330 ns. The file is synced once at close and exit.
- *A held read snapshot* (`docs/DB.md` §3.4): a Nextomic read reuses
  the file's last read transaction, with the trees it has opened, while
  no commit has passed it. §3.11's lookups 24.6 → 13.5 ms; through
  `bin/nexis`, 10,000 `(d/db conn)` 4.63 → 0.77 ms, `d/entity` plus one
  attribute 16.9 → 8.6 ms, `d/entid` by lookup ref 8.5 → 4.3 ms (§11).
  The query and pull rows of §3.7 each run one read and did not move
  outside their spread.
- *A safe point where a native calls a native* (`docs/GC.md` §7):
  `VM.callValue` checks the collector before it calls a non-closure,
  whose arguments are rooted. `(reduce conj [] xs)` over a million
  elements peaked at 15.5 MB live against 193 KB kept before and under
  3× the kept set after (the `eval_pipeline` test).
- *Calls from natives* (§3.13): a keyword or symbol callee looking
  itself up in place in `call:call` (`docs/VM.md` §8), a sequence
  native's callback prepared once (`vm.Callback`, VM.md §6), a vector or
  list stepped and a root pushed inline in the native's loop, and `+`,
  `inc`, `dec`, `even?` and `odd?` on fixnums inline (VM.md §10.3).
- *Marking in place, one root at a time* (`docs/GC.md` §4): the drain
  traces what a popped header's trace marks there and then, four levels
  deep, and `collect` drains after each root. The gray worklist stays at
  17 entries where the pipeline's setup grew it to 1.3 M (10.4 MB, kept
  between cycles).
- *Results built in place* (`docs/LIST.md` §1, `docs/VECTOR.md` §5):
  `mapv`, `filterv`, `vec` and the consuming natives that gather a
  result (`Results`) write each value past the 32nd into the open tail
  of the vector they return, never into a buffer on the root stack or a
  malloc'd list (§3.14).
- *Frameless fast handlers* (`docs/VM.md` §8, §3.19): the hot opcodes'
  fast handlers over the general table, reaching the general handler
  through the table indexed at run time, and release builds without a
  frame pointer. A first attempt tail-called the general handler
  through a constant function pointer; the compiler inlined it back and
  kept the stack frame the fast path was meant to drop.
- *A built sequence walked as its vector* (`docs/LIST.md` §3,
  `viewCursor`): a list that views a vector steps through the vector.
- *The loop's shape* (§3.16, `docs/COMPILER.md` §5.6, §5.7): a `recur`
  orders its arguments so none waits in a temporary, and repeats the
  loop's test at its bottom.
- *`+`, `*` and `-` inlined at any arity* (§3.17, `docs/COMPILER.md`
  §4.3): every argument computed, then a left fold of `math`
  instructions, as the native computes it.
- *Self-calls* (§3.23, `docs/COMPILER.md` §5.5): a `fn*` calling its
  own name at its fixed arity is `call:self`.
- *The keyword lookup instruction* (§3.24, `docs/VM.md` §6): `(:k x)`
  and `(:k x d)` are one `call:lookup` or `call:lookup-or`; destructuring
  binds a keyword or symbol key through it.
- *Per-arity entry points* (§3.30, `docs/VM.md` §5): a multi-arity `fn`
  is a routine per clause over one arity table.
- *Locals clearing* (§3.29, `docs/COMPILER.md` §4.9): each `mov:move`
  of a slot no path reads again is `mov:move-clear`, so a lazy seq a
  local or a parameter holds is let go as it is walked.
- *Leaf natives with a general body* (§3.22, `docs/VM.md` §6): `get`,
  `count`, `nthnext`, the kind predicates, `conj`, `assoc`, `assoc!` and
  `str` are called in place and refuse what could run code or walk
  nested data.

**Dead ends, measured and reverted** (hosts of §3.7 and §3.8):

- *A map literal's sort* (§3.41's Linux host, `perf stat` per unit,
  three rounds, against §3.41's after build). Sorting a word per entry,
  its key, and gathering the entries once in the keys' order: a
  three-entry literal 6.7 → 16.7 blocked loads and 335 → 374 cycles,
  the destructuring loop 815 → 862 M cycles. An insertion sort that
  moves each entry whole for a literal's at most 16: the literal 6.7
  → 0 blocked loads and 332 → 315 cycles, and the pipeline's setup 7.0
  → 0.4 M, but the destructuring loop, a two-entry literal an
  iteration, 822 → 865 M cycles on 83 M fewer instructions, with its
  memory-ordering machine clears 0.25 → 0.46 M, as a load issued
  ahead of the store of an entry at an index the loop computes makes.
- *The boundary's other widths* (§3.40's Linux host, `perf stat` per
  unit, three rounds each). Reading `callLeaf`'s result a word at a
  time alone: `leaf` 75.3 → 67.7 cycles, but the destructuring loop's
  cycles unchanged, its blocked loads 17.5 → 16.5 M, the rest moved to
  the natives' reads of arguments the handlers stored as words. Every
  handler store whole (one 16-byte store): a closure call (`gcall`)
  49.6 → 50.6 cycles and `cb` 41.8 → 44.4, a handler's 8-byte loads
  taking a 16-byte store's data a cycle later. `callLeaf` copying up to
  four arguments into a buffer stored whole, the handlers' stores left
  words: `getnl` 96.6 → 105.1 cycles. A leaf entry per leaf native
  (`NativeFn.leaf` a function of the arguments and an out-pointer,
  generated with the body inlined): `vnth` 73.3 → 66.3 cycles, but
  `getnl` and `leaf` 7–16 more instructions and the destructuring loop
  943 M cycles against 929 M without it. Zig's `x86_64_v3` target with
  `slow_unaligned_mem_16` added copies a `Value` with the same 16-byte
  loads: LLVM ignores the feature where AVX is present.
- *The transaction entity taken as fresh* in expansion, so the
  `:db/txInstant` datom skips the two probes of committed state a
  new entity skips (the entity of `t` has none: `checkEid` refuses a
  later transaction's), and *insertion sort* for a batch of at most
  16 datoms in `Store.writeBatch` in place of `std.mem.sort`'s block
  sort: −0.8 to −2.0% and +0.3 to −0.6% instructions on §3.27's four
  shapes against the build with trees opened on first use (five
  interleaved rounds, load 6.5 → 9.6), under the 3% a lever must
  win. What else Nextomic does per transaction is under 5% a part
  (§3.27); the page work is emdb's (`TODO.md` #2).

- *Clearing a closure's call block on return* (the part of the
  callee's window in the caller's frame, from the callee slot to the
  caller's stack extent), beside a native's (§3.21): `fib` 280.3 →
  296.0 instructions a call (+5.6%), `gcall` 270.0 → 284.0 (+5.2%),
  cycles unchanged, on the host of §3.21 (`bench/micro/run.clj
  --rounds 3`, load 4.4). A closure's arguments are its own slots
  while it runs, so the clearing frees nothing until the caller's
  next call reuses them; it was not kept.

- *Results through the transient's `conj!`*: `vectorConjBang` for
  every value, the tail's capacity read from its slab each time, cost
  the pipeline's phase 85 M instructions (+6 %) over the root-stack
  buffer it replaced. *A leaf's worth copied from the root stack*
  (32 values waiting there, then appended whole) cost 17 M over §3.13's
  build of the same tree. Writing into the open tail copies nothing.
- *Both of `Results.add`'s paths inline* in the native's loop: the
  filter stage's fastest of fifteen runs 35.0 ms against 29.1 ms with
  the rare path (the first 32 values, a full tail) out of line, and
  the phase's median 39.4 against main's 34.3 ms over 25 alternating
  runs, at equal instructions. A code-layout effect: the same source
  with two `getenv` calls added elsewhere ran at main's speed.
- *Prefetching a vector leaf's heap elements* when the cursor loads
  the leaf, so the pipeline's first touch of each row's map (§3.13)
  would find it in flight: the phase's median 38.2 → 40.3 ms and
  40.5 → 43.9 ms over two runs of ten, alternating. The maps were
  allocated in order and the hardware's own prefetch already follows
  them; 32 prefetches at each leaf only add traffic.

- *Keeping the switch loop's frame pointer across instructions*, the
  fetch re-deriving it only after a group that can change `frames`:
  `vm_loop_10k` 267 → 314 μs in one run and within noise in three
  more. The loads it saves cost less than what the loop-carried
  pointer costs the register allocator. The threaded dispatch passes
  the frame as a handler argument, in a register by the calling
  convention (§3.12).
- *Running a `jump:jmp` that follows a `mov:move` in the move's
  dispatch*, the `recur` back-edge, as a comparison runs its branch:
  the 1M-iteration loop's minimum was 15.9 ms both ways over fifteen
  alternating runs, and every other move paid the test.
- *One copy for string values leaving an index key*
  (`key.unescapeFrom` copying the run before the first NUL whole):
  no §3.7 row moved outside its spread. Key decoding is about 5 % of
  a query row, under the run-to-run spread; borrowing the page bytes
  would save the same 5 % and bind the relation's lifetime to the
  read transaction.
- *A measured `refs_per_value` for the planner*: the store keeps a
  per-attribute datom count but no distinct-value count, so measuring
  it means a sampling scan of VAET at plan time or a `sys` counter
  every ref write maintains. Neither can move a §3.7 row: the join
  kind is chosen per step from the actual input rows
  (`plan.nestedLoop`), and every corpus query's clause order is
  already the one a correct estimate picks. Only a skewed corpus
  would differ, and none exists.
- *Comptime monomorphization of `mapAssoc`/`setConj` for keyword
  keys* beyond the inline hash: assoc and conj stayed within noise at
  every N; the remaining cost is path copying and allocation (§3.2).
- *A Var's load run with its call*: a call whose arguments run no
  code read its Var callee last, just before the `call:call`, and the
  `var:load-var` quickened with the call (`var:load-var.s+call`) ran
  the pair as one dispatch, reading the Var at every execution. One
  dispatch fewer per eligible call, the native counts the same, took
  3.6% of `leaf`'s instructions, 4.2% of `gcall`'s, 2.7% of `getnl`'s
  and 3.3% of `vnth`'s (§3.37), under the 8% it had to win on each:
  a dispatch is about ten instructions. Not kept.
- *Calls of one or two arguments in place*: `call:call1 A=dst B=arg
  C=callee` and `call:call2 A=callee B=arg C=arg`, reading their
  arguments where they are, a constant, a slot, an upvalue or a Var,
  with no block staged; clearing forms that left a dead argument's
  slot nil; quickened forms of slot, constant and Var operands; and a
  callee's `var:load-var` run with the `call:call2` after it. The
  closure path opened the callee's window at the stack's length, as
  `callValue` does; a native that is not a leaf got its arguments
  written past the stack's length, rooted while it ran; everything
  else went through `call:call`'s general entry from a block written
  there. Every call order, redefinition, binding and `with-redefs`
  case held, and every peak resident set, but the rows fell 6.6–21%
  above `count` where they had to fall 20–35%, and the destructuring
  loop 2.4% of its instructions where it had to fall 8% (§3.37): the
  moves and dispatches went, and an in-place call's out-of-line part
  costs what `callLeaf` does. What a leaf call through a Var costs
  past that is the native's own body (`count` of a vector is 61
  instructions) and the out-of-line part's frame; nothing in the
  call's encoding reaches either. Not kept.
- *A leaf call's kind and arity in one test* (§3.42's hosts, the
  micro kit against the build without it): a mask on the
  native's descriptor, a bit per argument count it takes as a leaf,
  read once by `callLeaf` in place of the leaf flag and the two
  arity bounds, and the frame's `pc` written on the error path alone.
  Six instructions fewer a call: on the M5 `leaf1` 245.1 → 239.2
  (−2.4%), `vnth` 295.2 → 289.0 and `getnl` 294.2 → 288.1 (−2.1%); on
  the Linux host `leaf1` 53.0 → 50.4 cycles (−4.9%), `vnth` 60.9 →
  59.0 (−3.1%), `getnl` 60.1 → 58.4 (−2.8%) and `vdestr` 242.0 →
  245.3. Under the 5% a lever on these programs has to win. Finding the
  result's slot before the native call as well kept the instruction,
  the frame's base and the stack's items live across it, a fifth
  callee-saved register. Not kept.
- *A leaf's common case without a frame* (§3.42's builds): `count`,
  `nth` and `get` keep, on their vector path, the frame their other
  kinds need. A `count` whose vector test came before a body that
  merged the other kinds' counts into one return was frameless on
  arm64 (`leaf1` 262 → 245 instructions), but that return assembled
  its result in a temporary on x86-64, one blocked load a `count` of a
  list (`vdestr` 251.0 → 265.2 cycles). The rest of the body out of
  line, a call never inlined, copies its result on in the same way;
  a tail call of it (`.always_tail`) is refused by LLVM in Zig 0.17,
  whose `musttail` call returning an error union through memory fails
  the verifier; an `unlikely` hint on the rest moved nothing. Not
  kept.

---

## 7. Non-goals

- **Shared-memory multithreading inside one isolate.** Concurrency is
  many single-threaded isolates over emdb transactions; no CAS, no
  fences, no STM in the runtime.
- **A JIT.** The route is bytecode plus specialization and inline
  caches (§6).
- **Beating C or Zig on tight loops.** The comparison is with Clojure,
  not with the host language.
- **Zero-allocation steady state.** Persistent structures allocate;
  the work is to allocate less and cheaper.
- **Single-number headlines.** "N× faster than Clojure" without
  category, regime, input size and idiom tier is what BENCH.md §2 and
  §3 forbid.

---

## 9. Honesty

A new measurement goes into §3 once, with its host and run in §11,
and the scorecard row cites it. A measurement that contradicts an
expectation in §1 or §2 rewrites the expectation. An optimization
that measures slower is reverted and listed in §6's dead ends, not
kept with a caveat. Each §3 section says how its figures were taken.

---

## 11. Measurement provenance

| Rows | Host | Run |
|---|---|---|
| §3.1, §3.4's table, §3.6 M1 column | Apple M1, macOS, Zig 0.16.0, ReleaseFast | 2026-04-19; `src/bench.zig` + `bench/main.zig`, 30 samples of ≥50 ms each. These rows allocate nothing from the heap in their timed bodies |
| §3.2, §3.3, §3.4's M5 figures, §3.5 | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds (load average 4–7) | revamp, 2026-09-26, ws-collections: `nexis-bench --filter collection-construction,transient-construction,collection-lookup-update,codec`, built by `zig build bench -Doptimize=ReleaseFast` at `cc935cc` (before) and at the ws-collections head `5a1e9b4` (after); three invocations of each, alternating, the median of the three 30-sample medians with the three in brackets |
| §3.6 M5 column, §3.8 | Apple M5, 32 GiB, macOS 26.6, Zig 0.16.0, ReleaseFast, idle | `zig build bench -Doptimize=ReleaseFast`, five invocations per state of the tree, the best median with the spread; "before" is the tree at `739d24f`, "after" the `vm` and `champ` commits named in the table. That run had the pool under the benchmark heaps; its construction and codec-decode rows are dropped as pool figures. The `vm`, `compiler`, lookup and `db` rows do not allocate from the pool |
| §3.7 | Apple M5, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds (load average 6–20) | revamp, 2026-09-25: `nexis-bench --filter nextomic` built by `zig build bench -Doptimize=ReleaseFast` from `bench/nextomic.zig` at the ws-planner head over the `src/` of `8548eda` (before) and of the ws-planner head (after), five invocations of each, alternating, the best median with the spread; the `bin/nexis` figures are one run each of a probe program timing `d/q` with `nano-time`, before at `b8c17a1` |
| §3.9 | not recorded | revamp, 2026-09-25, ReleaseFast `bin/nexis run`, at the merge of the vector-view change (`7f44db5`) |
| §3.10 | Apple M5, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds | revamp, 2026-09-25: `zig build install -Doptimize=ReleaseFast` at `c4413b1` (before) and at the ws-codegen branch head (after); the probe program run nine times per build, alternating, each loop timed with `nano-time`; the `thrown?` figure a separate program, five runs per build |
| §3.11 collections and the heap | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds | revamp, 2026-09-26, ws-collections: `bb bench/compare/run.clj --n 10 --max-load 6 --workloads map-build-read,map-transient,vector-conj-nth,freq-group,pipeline,sort,startup` with the `bin/nexis` of the ws-collections head `5a1e9b4` (after), then of `f84ab80` (before), load 3.7–4.8 at the starts and ends; each workload started below a load average of 6 and repeated if the load rose past it |
| §3.11 language and database rows | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224, Datalevin 1.1.0; emdb `ee61850`; shared with concurrent sessions (load average 3.8 at the start and the end) | 2026-09-28 00:52 MDT: `bb bench/compare/run.clj --n 10 --max-load 5` at `7b50fa4`; ten rounds after a discarded warm-up (startup thirty), the implementations alternating, each workload started below a load average of 5 and repeated if the load rose past it; every answer equal; raw results kept with the run (`results.json`) |
| §3.11 sequences and strings | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds | revamp, 2026-09-26, ws-strseq: `bb bench/compare/run.clj --n 10 --workloads string-split,pipeline,destructure`, before at `cc935cc` (`--max-load 12`, load 27 falling to 8), after at `c0d6043` (`--max-load 6`); the instruction counts from `/usr/bin/time -l bin/nexis run` of each workload's program, five or seven runs per build, minus a run of its setup alone |
| §3.11 lazy sequences against the eager build | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; shared with concurrent builds (load average 3.4–5.6) | 2026-10-06, perf-regress: the `bench/compare` bodies of `pipeline`, `sort` and `freq-group` after `prelude.nx`, and `-e nil`, run by `bin/nexis` built with `zig build install -Doptimize=fast` at `3f1f9c6`, `240c2b4` and `c20942f`, 7 interleaved rounds under `/usr/bin/time -l`; a phase's instructions and cycles are its program's minus the same program without the timed part, its time the program's own `nano-time` figure, the resident set the process's maximum; medians |
| §3.36's v0.1.0 and L3 stages (emdb `8e1ed1e` and `b3370fb`) | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); shared with concurrent sessions (load average 20–45) | 2026-10-08, store: `zig build bench -Doptimize=fast -- --filter nextomic-store` at `0d5f691`, against emdb `8e1ed1e` (a source snapshot beside a snapshot of the tree) and emdb `b3370fb`; the trees from emdb's `treeStat` and a cursor walk of each (`Store.treeSize`), the file's allocated bytes from `stat`. Sizes do not depend on load |
| §3.12 | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds (load average 3–9) | revamp, 2026-09-26, ws-dispatch: `nexis-bench` and `bin/nexis` built at `968aa77` (before) and at `5f724d7` (after); `nexis-bench --filter vm,compiler` five times per build, alternating; `bb bench/compare/run.clj --n 10 --max-load 6 --no-build --workloads fib,loop,destructure,sort,map-build-read,pipeline` four times, the builds alternating, each run's report naming the tree's head since the binary was swapped in |
| §3.13, §6 "Calls from natives" | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds (load average 3–18) | 2026-09-27, ws-pipeline-calls: `bin/nexis` and `nexis-bench` built at `a712a24` (before) and at the branch head (after); `bb bench/compare/run.clj --n 10 --max-load 6 --no-build --workloads pipeline,fib,loop,destructure` four times, after, before, after, before, the binary swapped into one worktree, so each report names the branch head; `zig build bench -Doptimize=ReleaseFast -- --filter vm` five times per build, alternating; the instruction counts from `/usr/bin/time -l bin/nexis run` of the pipeline's program cut after each stage, median of five, the setup's own run subtracted; the per-step figures of §6 from each commit's build against the one before it, the phase timed with `nano-time` inside `bin/nexis run` of the pipeline program, ten runs each, alternating |
| §3.14, §6 "Marking in place", "Results built in place", "A built sequence walked as its vector" and their dead ends | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds (load average 3–16) | 2026-09-27/28, ws-pipeline-heap: `bin/nexis` built at `a712a24`, at `8afd353` (main with ws-pipeline-calls) and at the branch head; the cycle and heap figures from a build of `a712a24` with a trace printed at each cycle and at exit; `bb bench/compare/run.clj --n 10 --max-load 6 --no-build --workloads pipeline,map-build-read,map-transient,vector-conj-nth,sort,freq-group` once with `a712a24`, then four times, branch head and `8afd353` alternating, the binary swapped into the branch's worktree, so each report names the branch head; the instruction counts from `/usr/bin/time -l bin/nexis run` of the pipeline program and of its setup alone, five runs each, the median; the trigger table from a build reading the growth and floor from the environment, not committed; the step figures of §6 against the build before each step |
| §3.15 | Intel Core Ultra 9 185H (6 performance cores with 2 threads each, 8 efficiency and 2 low-power cores; 22 logical CPUs), 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, ext4 on NVMe, cpufreq governor `powersave` (left as the host has it); every process pinned with `taskset -c 0-11`, the performance cores' threads (4.8–5.1 GHz maximum); nexis `97e2d11` and emdb `8e1ed1e` (source snapshots, not checkouts), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); babashka v1.13.224; Datalevin 1.1.0; Temurin OpenJDK 21.0.12.1, Clojure CLI 1.12.6.1673, Clojure 1.12.6, the JDK's default flags with `-XX:-UsePerfData` and `-Djava.io.tmpdir` (the CLI adds `-XX:-OmitStackTraceInFastThrow`); Datomic Local 1.0.291; Datomic Pro 1.0.7705, dev transactor with its distribution's JVM options and the dev template's memory settings; a host shared with other sessions' builds, each piece run holding the host's benchmark lease, which drains the other work first (1-minute load average 1.4–3.8 at the pieces' starts and ends, but 5.5 at one start, which the runner waited out before its first workload; at most 3.6 during a workload) | 2026-10-07 22:16 – 2026-10-08 00:13 MDT: `bb bench/compare/run.clj --n 10 --max-load 4 --pin 0-11 --no-build --nexis-commit 97e2d11 --emdb-commit 8e1ed1e --datomic-pro DIR` in seven pieces, `--only lang --impls nexis,bb,clojure` over `startup,loop,fib,string-split`, `sort,freq-group,vector-conj-nth`, `map-transient,destructure` and `map-build-read,pipeline`, and `--only db` with `--impls nexis,datalevin`, `nexis,datomic-local` and `nexis,datomic-pro`; ten rounds after a discarded warm-up (startup thirty), the implementations alternating, the Clojure warm column the median of ten calls after twenty in one JVM; every workload on its first attempt, below the load limit of 4; every answer equal. The durability of each system from `strace -f` of 200 one-datom transactions on the same host (2026-09-28, nexis `95791b0`); `create`'s syncs from `strace -f -T` of a program running the phase. The `sort` figures: `perf stat` and `perf record -e cpu_core/cycles/u` (`perf annotate` of `mergeSort`) of the row's program under `taskset -c 2`, three runs of each `bin/nexis`, built at `95791b0` by Zig 0.16.0, at `1489ef9` (over emdb `847c5d8`) and at `97e2d11` by Zig 0.17.0. |
| §3.16 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; babashka v1.13.224; emdb `847c5d8`; shared with concurrent builds | 2026-10-06, speed-c: `bin/nexis` and `nexis-bench` built with `-Doptimize=fast` at `b0ba2ae` (before) and at the branch's loop-shape commit (after). Micro programs: `python3 harness.py OUT 7 A,B -- count.nx:5000000 count.nx:10000000 acc.nx:… fib.nx:27 fib.nx:30 gcall.nx:… lc.nx:…` under `tools/heavy` (one core), load 9.5 at the start and 9.4 at the end; the `bench/compare` programs as `run.clj` writes them, whole process by `cmds.py` five rounds (load 8.9 → 8.6) and the self-timed phase nine interleaved rounds (load 4.4 → 4.3); `bb bench/compare/run.clj --n 10 --only lang --impls nexis,bb --no-build --max-load 16` four times, after, before, after, before (load 10.3 → 9.6), every answer equal; `nexis-bench --filter vm,compiler` five times per build, alternating (load 5.0 → 4.9). |
| §3.17 | as §3.16 | 2026-10-06, speed-c: `bin/nexis` built with `-Doptimize=fast` at the loop-shape commit (before) and at the branch's arithmetic commit (after). `harness.py OUT 7 A,B -- add3.nx:5000000 add3.nx:10000000 count.nx:… fib.nx:27 fib.nx:30 gcall.nx:…` (`add3.nx`: `(loop [i 0 acc 0] (if (< i n) (recur (inc i) (+ acc i 1 2)) acc))`, kept with the raw output), load 5.1 → 4.6; the `bench/compare` programs by `cmds.py`, five rounds, and their phases, nine interleaved rounds (load 4.2 → 4.1); `run.clj --n 10 --only lang --impls nexis,bb --no-build --max-load 16` four times, after, before, after, before (load 4.0 → 12.8), then `--workloads fib,sort,string-split,vector-conj-nth,destructure` four times, before first (load 12.4 → 10.5); every answer equal. |
| §3.18, §6 "The stdlib image" | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `847c5d8`; shared with concurrent sessions (load average 3.97 at the start, 3.89 at the end) | 2026-10-06 12:22 MDT, speed-b: `bin/nexis` built by `zig build install -Doptimize=fast` at `b0ba2ae` (before) and `587f87f` (after); `cmds.py OUT 21 'A=… -e nil' 'B=… -e nil'` and the same for `-e '(+ 1 2)'`, under `tools/heavy` (1 core); the load phases from a probe build returning after each phase, five runs each, the median; raw results in the revamp ledger (`bench/speed-b/`) |
| §3.18 the image's verification | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; emdb `847c5d8`; shared with concurrent builds (load average 8.81 at the start, 9.23 at the end) | 2026-10-06 15:55 MDT, speed integration: `bin/nexis` built by `zig build install -Doptimize=fast` at `01e77a0` with the loader's verification, once with it compiled in and once without; `cmds.py OUT 21 'V0=… -e nil' 'V1=… -e nil'` under `tools/heavy` (1 core) |
| §3.19 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; emdb `847c5d8`; shared with concurrent builds (load average 4–15 at the starts and the ends) | revamp, 2026-10-06, speed-v: `bin/nexis` built by `zig build install -Doptimize=fast` at `305eee3` (one table), `390d571` (fast handlers), `07dd8ce` (`pc` in a register), `b873368` and `1cc9e23` (the hot section), `9bcd928` (verified) and `c4b60cf` (the host's cell), each against the one before it in its own run; `bb bench/micro/run.clj --rounds 5 --programs count,acc,fib,gcall,lc,mv,lv,kw,leaf,getnl` (seven rounds for the hot section and the verified build, fifteen and twenty-five for the rows the text cites, the callback programs for the host's cell) under the machine's core queue, one core |
| §3.19 phase table and language rows | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; emdb `847c5d8`; shared with concurrent builds (load average 4–9) | revamp, 2026-10-06, speed-v: `bin/nexis` of `b0ba2ae` and of `93862af` (`ea38a91` for the language rows), `zig build install -Doptimize=fast`; `bb bench/micro/run.clj --rounds 5` over every program; the language rows' instructions and cycles from `/usr/bin/time -l bin/nexis run` of each `bench/compare` program (prelude and body), one run each; `bb bench/compare/run.clj --no-build --only lang --impls nexis --n 10 --max-load 16` twice per build, alternating, the binary copied into the worktree's `bin/`; the pipeline's phase from its own report, three runs of each build; startup `-e nil` seven runs each; |
| §3.20 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); babashka v1.13.224; emdb `847c5d8`; shared with concurrent sessions | 2026-10-06 16:13–16:19 MDT, speed integration: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `70db20b` (before) and `35a85bd` (after). Micro kit: `bb bench/micro/run.clj --rounds 7 BEFORE AFTER` under `tools/heavy` (1 core), load 5.05 → 6.58 (a five-round run during the gate, load 6.2 → 7.3, gave the same instructions). Startup: `cmds.py OUT 21` over `-e nil` and `-e '(+ 1 2)'` of each, load 5.94. Language rows: `bb bench/compare/run.clj --out DIR --n 10 --only lang --impls nexis,bb --no-build --max-load 16` four times, after, before, after, before, the binary copied into a worktree of `70db20b`, so each report names that commit (load 5.41 → 5.51); the whole-process counters `cmds.py OUT 5` over each `DIR/src/<row>.nx` (load 5.13 → 5.23). |
| §3.21 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `847c5d8`; shared with concurrent sessions | 2026-10-06, speed2-v: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `f51a5d0` (before) and at each change of the section (after), each against the one before it. Micro kit: `bb bench/micro/run.clj --rounds 5 BEFORE AFTER` under `tools/heavy` (1 core), the load at the start and the end in the text. The `bench/compare` programs (prelude and body) under `/usr/bin/time -l`, five interleaved rounds by `harness.py`, the phase each program reports. The counting-loop figures of the assertion: `bin/nexis run bench/micro/count.nx 10000000`, twelve runs of each build. The database rows: `bb bench/compare/run.clj --n 10 --only db --impls nexis --no-build --max-load 16`, four runs alternating the binary in the worktree's `bin/`. |
| §3.22 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); babashka v1.13.224; emdb `847c5d8`; shared with concurrent sessions | 2026-10-06 16:50–17:19 MDT, speed2-s: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `f51a5d0` and after each of the eight steps (`95d5497` … `e9ecc12`). Micro programs: `harness.py OUT 5` over all nine builds, `count`, `gcall`, `leaf`, `getnl` and one program per step (`getm`, `cnt`, `seqq`, `nnext`, `conjv`, `assocm`, `assocb`, `strn`, kept with the raw output) at 5 M and 10 M iterations and `fib` at 27 and 30, under `tools/heavy` (1 core), load 9.88 → 7.84. The `bench/compare` programs (prelude and body) by `cmds.py OUT 7` over all nine builds, load 9.50 → 9.08. `bb bench/compare/run.clj --n 10 --only lang --impls nexis,bb --no-build --max-load 16` four times, after, before, after, before, from a copy of `bench/` (load 8.61 → 7.58). |
| §3.23 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); babashka v1.13.224; emdb `847c5d8`; shared with concurrent sessions | 2026-10-06 21:10–21:16 MDT, speed3-c: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `32fd022` (before) and at the self-call commit (after). Micro programs: `harness.py OUT 7` over `fib` at 27 and 30 and `count`, `gcall`, `lc`, `kw` at 5 M and 10 M iterations, under `tools/heavy` (1 core), load 2.08 → 1.99. The `bench/compare` programs (prelude and body) by `cmds.py OUT 5`, load 1.86 → 1.81; `-e nil` by `cmds.py OUT 21`. `bb bench/compare/run.clj --n 10 --only lang --impls nexis,bb --workloads fib,loop,destructure,pipeline --no-build --max-load 16` four times, after, before, after, before, from a copy of `bench/` (load 2.17 → 3.14). |
| §3.24 | as §3.23 | 2026-10-06 21:18–21:24 MDT, speed3-c: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at the self-call commit (before) and at the keyword lookup commit (after). `harness.py OUT 7` over `kw`, `count`, `gcall`, `lc` at 5 M and 10 M iterations and `fib` at 27 and 30, load 2.62 → 2.89; the `bench/compare` programs by `cmds.py OUT 5` (load 2.89 → 2.95) and their phases by `cmds.py OUT 9` (load 3.92); `run.clj` as §3.23 over `pipeline,fib,loop,destructure` (load 4.35 → 4.01). Destructuring through it: the keyword lookup commit (before) against the destructuring commit (after), 21:29–21:31 MDT; `harness.py OUT 7` over `destr` (`(let [n … m {:a 1 :b 2}] (loop [i 0 acc 0] (if (< i n) (recur (inc i) (+ acc (let [{:keys [a b]} m] (+ a b)))) acc)))`, kept with the raw output), `kw`, `count`, `gcall`, `fib`, load 2.72 → 2.85; `cmds.py OUT 5` and `OUT 9` (load 2.85 → 2.79); `run.clj` over `destructure,pipeline,fib,loop` (load 3.05 → 4.65). |
| §3.25 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); babashka v1.13.224; emdb `847c5d8`; shared with concurrent sessions | 2026-10-06 22:18–22:34 MDT, speed4: `bin/nexis` and `nexis-bench` built by `zig build install -Doptimize=fast --prefix DIR` (and `zig build bench`) at `297c146` (before) and at the quickening commit (after). Micro programs: `harness.py OUT 7` over `count`, `acc`, `gcall`, `lc`, `mv`, `lv`, `kw`, `leaf`, `getnl`, `destr` at 5 M and 10 M iterations and `fib` at 27 and 30, under `tools/heavy` (1 core), load 3.22 → 3.49; `cbbase`, `cbsum`, `cbred`, `cb`, `lazy` at 1 M and 2 M, five rounds (load 3.54 → 3.58). The `bench/compare` programs (prelude and body) by `cmds.py OUT 5` (load 3.58 → 3.30); startup by `cmds.py OUT 21` over `-e nil` and `-e '(+ 1 2)'`; `run.clj --n 10 --only lang --impls nexis,bb --workloads loop,fib,destructure,pipeline --no-build --max-load 16` four times, after, before, after, before (load 3.30 → 2.89); `nexis-bench --filter vm,compiler` five times per build alternating, `--filter compiler` seven more. |
| §3.26, §6 "The counting-loop step" | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); babashka v1.13.224; emdb `dbc5c78`; shared with concurrent sessions | 2026-10-07 18:28–18:31 MDT, spd14: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `0ef07a3` (before) and at the step commit (after). Micro programs: `harness.py OUT 7` over `count`, `acc`, `gcall` at 5 M and 10 M iterations and `fib` at 27 and 30, under `tools/heavy` (1 core), load 5.81 → 5.67; the `bench/compare` language programs (`prelude.nx` and body) by `cmds.py OUT 5`, load 5.67 → 5.99; `bb bench/compare/run.clj --n 10 --only lang --impls nexis,bb --workloads loop,destructure,fib,pipeline --no-build --max-load 16` four times, after, before, after, before, the binary swapped into one copy of the tree, load 3.92 → 3.42. The histograms of §6: speed4, 2026-10-06, `-Dopcodes=true` at the quickening commit. |
| §3.27, §6 "Trees opened on first use" and its dead ends | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); Datalevin 1.1.0; emdb `8e1ed1e` (a source snapshot under both builds); shared with concurrent sessions | 2026-10-07, txperf: `bin/nexis` built by `zig build install -Doptimize=fast` from snapshots of `0ef07a3` (before) and `a787b2f` (after) beside one emdb snapshot. The shapes: `txbench.py OUT 9 A,B plain,entity,upsert,one 2000 10000` over the probe program `tx.nx` (both kept with the raw output), each run in a fresh store under `/usr/bin/time -l`, under `tools/heavy` (1 core), 19:03 MDT, load 9.18 → 7.78; a rerun at load 20.3 → 21.4 gave the same instructions within 0.3%. The dead ends: the same harness, five rounds over four builds, load 6.48 → 9.56. Pages: a build of `0ef07a3` over emdb `dbc5c78` printing emdb's dirty-page count before each commit, the same program at both sizes. `bb bench/compare/run.clj --no-build --n 10 --only db --impls nexis --max-load 16` four times, after, before, after, before, 19:04–19:16 MDT, load 5.61 → 5.02. The Datalevin run: `run.clj --no-build --n 10 --only db --impls nexis,datalevin --max-load 16` with the after build, 19:34–19:38 MDT, load 19.96 → 4.26. The profile: `perf record -e instructions:u --call-graph lbr -F 900` and `perf script --inline` on the host of §3.15 (`taskset -c 0`, nexis at `a787b2f`'s source, emdb `dbc5c78`), `tx.nx STORE 200000 entity`; the before figure from `0ef07a3` over `tx1.nx`, the same shape without the 20,000 loaded first, 300,000 transactions. |
| §3.28 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); shared with concurrent sessions | 2026-10-07, multi: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` on `0ef07a3` with this section's commits, before §3.26's counting-loop step: at the micro-program commit, whose runtime is the multimethods commit's (before), and at the `#%mm-lookup` commit (after); `bb bench/micro/run.clj --rounds 5 --programs count,gcall,pcall,casek,mcall BEFORE AFTER` under `tools/heavy` (1 core), load 7.80 → 7.02; the dispatch and native counts from `-Dopcodes=true` builds of each, `mcall`, `pcall`, `gcall` and `casek` at 100,000 and 200,000 iterations, the difference per iteration; the one-arity figure from a probe program calling the same cache through a one-arity closure, at 1 M and 2 M. |
| §3.29, §6 "Locals clearing" | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `24027c8`; shared with concurrent sessions | 2026-10-07 21:48–22:10 MDT, locals: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `97e2d11` (before) and `22d9391` (after), and with `-Dopcodes=true` at `97e2d11` and `6da3c15`. Micro kit: `bb bench/micro/run.clj --rounds 5 BEFORE AFTER` over every program under `tools/heavy` (1 core), load 5.26 → 5.42. The memory rows: `cmds.py OUT 3` over `lazy3`, `lazyl`, `lazyf` at 3 M and 30 M, load 4.81 → 5.26. The `bench/compare` language programs (`prelude.nx` and body) by `cmds.py OUT 5`, load 5.16 → 7.13; startup by `cmds.py OUT 21` over `-e nil`. `nexis-bench --filter compiler` twice per build, interleaved, after at `1d63d19`; the image generator, each tree's debug `nexis-imagegen`, `cmds.py OUT 7`. |
| §3.30, §6 "Per-arity entry points" | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `19d9002`; shared with concurrent sessions | 2026-10-08, arity: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `fb51779` (before) and at the `expand` commit (after), and with `-Dopcodes=true` at each. Micro kit: `bb bench/micro/run.clj --rounds 5 BEFORE AFTER` over every program but the lazy pipelines under `tools/heavy` (1 core), load 13.01 → 7.85. The `bench/compare` language programs (`prelude.nx` and body) by `cmds.py OUT 5`, load 5.75 → 5.25; startup by `cmds.py OUT 21` over `-e nil`. Dispatch and native counts: `gcall`, `acall`, `vcall`, `mcall` and `xform` at 100,000 and 200,000, `fib` and `afib` at 20 and 22, the difference per unit. The image figures from each tree's `stdlib.image` header. |
| §3.31 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); shared with concurrent sessions | 2026-10-08 01:27–01:42 MDT, consume: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `efff7a7` (before) and `193ad6d` (after, with `set` consuming, which the `set` comparison measures and which no other row runs). The memory rows: `cmds.py OUT 3` over the `count`, `into` and `vec` programs at 3 M and 30 M (`mem.*`, load 5.86 → 6.35) and over the `i64-vector`/`take-last` program (`mem2.*`, load 9.62 → 11.29); the `set` comparison `cmds.py OUT 3` (`mem3.*`, load 14.59 → 11.27); the `into` a hash set comparison `cmds.py OUT 5` against a build whose `into` is `193ad6d`'s (`mem4.*`, load 12.65 → 17.21). Micro kit: `bb bench/micro/run.clj --rounds 5 BEFORE AFTER` under `tools/heavy` (1 core), load 6.89 → 7.89. The `bench/compare` language programs (`prelude.nx` and body) by `cmds.py OUT 5`, load 7.67 → 9.58. |
| §3.32, §6 "Sort keys compared in registers" | Intel Core Ultra 9 185H, 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, governor `powersave`, as §3.15; babashka v1.13.224; and Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434); Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `19d9002` (a source snapshot on the Linux host); both hosts shared with other sessions | 2026-10-08 01:16–01:43 MDT, sortcmp: `bin/nexis` built by `zig build install -Doptimize=fast` from source snapshots of `efff7a7` (before), of `efff7a7` with the fixnum path alone (A), with the direct call alone (C) and with both (after, `8e6fbf5`'s code). Programs: `bench/compare/prelude.nx` with `lang/sort.clj`, and with the same body over `(mapv (fn [i] (str (mod (* i 7919) 1000003))) (range 300000))` (`sortstr.nx`, kept with the raw output). Linux: `perfpairs.sh`, each run `taskset -c 2 perf stat -x, -e cpu_core/instructions/u,cpu_core/cycles/u bin/nexis run P`, the builds interleaved, five rounds, holding the host's benchmark lease (load 1.1 → 1.2, and 1.2 for the run with C); `run.clj --n 10 --max-load 4 --pin 0-11 --no-build --only lang --impls nexis,bb --workloads sort` from each snapshot, before, after, before, after (load 1.8 → 2.1); the merge loop's code from `objdump -d` of each build's `stdlib.mergeSort`. M5: `macpairs.sh`, each run `/usr/bin/time -l bin/nexis run P`, the builds interleaved, seven rounds under `tools/heavy` (1 core), load 5.4 → 5.1, and 17 for the run with C. |
| §3.33, §6 "Closures called from natives" | Intel Core Ultra 9 185H, 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, governor `powersave`, as §3.15; babashka v1.13.224; and Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434); Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `19d9002` (a source snapshot on the Linux host); both hosts shared with other sessions | 2026-10-08 13:06–13:08 MDT, callback: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` from `0a420b8` (before), `ac1fd7c` (A1), `8645b10` (A2) and `37dad1e` (B), and with `-Dopcodes=true` at `0a420b8` and `37dad1e`; on the Linux host from source snapshots of `0a420b8`, `8645b10` and `37dad1e`. Micro kit: `bb bench/micro/run.clj --rounds 5` over the four builds under `tools/heavy` (1 core), load 11.3 → 14.8; each lever's own A/B run against the build before it is in its commit. The language programs (`prelude.nx` and body) by `cmds.py OUT 5`, load 14.7 → 17.4. Linux: `perfpairs.sh`, each run `taskset -c 2 perf stat -x, -e cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/ld_blocks.store_forward/u bin/nexis run P`, the builds interleaved, five rounds, holding the host's benchmark lease (load 1.1 → 1.2); `perf record -c 1009 -e cpu_core/ld_blocks.store_forward/u` and `-c 20011 -e cpu_core/cycles/u` of each row, and `perf annotate vm.VM.callPrepared`; `run.clj --n 10 --max-load 4 --pin 0-11 --no-build --only lang --impls nexis,bb --workloads pipeline,vector-conj-nth` from each snapshot, before, after, before, after (load 1.3 → 1.4). Dispatch counts: every micro program at 100,000 (`fib` 20), both rows and a probe program, each build's CSV compared. |
| §3.34, §6 "`sort`'s buffers" and "`vec` of a vector's view" | Intel Core Ultra 9 185H, 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, governor `powersave`, as §3.15; babashka v1.13.224; and Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434); Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `b3370fb` (a source snapshot on the Linux host); both hosts shared with other sessions | 2026-10-08 15:36–15:57 MDT, sortbuf: `bin/nexis` built by `zig build install -Doptimize=fast` at `fd5ef10` (before) and `45068cc` (after), on the Linux host from source snapshots of each; on the M5 also the after code with `SortOrder.less` not inline, and a trial build whose `vec` returns a list view's vector, one run of each. Programs: `bench/compare/prelude.nx` with `lang/sort.clj`, with its body's `(sort xs)` alone (`sortonly.nx`), `(sort-by - xs)` (`sortby.nx`), `(sort > xs)` (`sortcmpf.nx`), and §3.32's `sortstr.nx`, kept with the raw output. Linux: `perfpairs.sh`, each run `taskset -c 2 /usr/bin/time -f %M perf stat -x, -e cpu_core/instructions/u,cpu_core/cycles/u bin/nexis run P`, the builds interleaved, five rounds, holding the host's benchmark lease (load 1.5 → 2.3); `run.clj --n 10 --max-load 4 --pin 0-11 --no-build --only lang --impls nexis,bb --workloads sort` from each snapshot, before, after, before, after (load 1.9 → 1.9; its report names the `zig` on the path, not the one that built). M5: `macpairs.sh`, each run `/usr/bin/time -l bin/nexis run P`, the builds interleaved, seven rounds under `tools/heavy` (1 core), twice (load 22.9 → 22.8 and 22.0 → 20.3; the tables are the second). |
| §3.35 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); shared with concurrent sessions | 2026-10-08 16:13–16:44 MDT, seqfix: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `ced34dc` (before: `0c7d082` before its rebase onto `e115f57`, which brings §3.34's `sort`) and at the commit that adds §3.35 over the same base (after; the `zipmap` rows with its values consumed as well, `zipmap` alone differing). Programs (`rev`, `butl`, `mapv`, `filtv`, `apply`, `zipm`, `selk`, `join`, `joini`, the vector controls and the loops of small calls) kept with the |
| §3.36, §3.11's and §3.15's store rows, §6 "Store size" | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast (`-Doptimize=fast`), emdb `b3370fb` (`8e1ed1e` for the v0.1.0 stage, a source snapshot), shared with concurrent sessions (load 6–45); and the Linux host of §3.15, Zig 0.17.0 (`tools/zig-0.17`; `run.clj` reports the host's default `zig`), emdb `b3370fb` (a source snapshot) | 2026-10-08, store. Sizes: `zig build bench -Doptimize=fast -- --filter nextomic-store` at each stage's commit (snapshots of `0d5f691` under both emdbs, `f4b2072`, `4dd916a`, `05ed7a1`). Reads on the M5: `q.nx STORE MODE N` (a probe over the `nexis-load.nx` store, its churn variant after two rounds of 20,000 salary changes) under `tools/heavy /usr/bin/time -l`, N1 and N2 per mode, three interleaved rounds, `78f0f3b` against `b2c4eaa`. Transactions on the M5: `tx.nx STORE N MODE` (§3.27's probe plus a `retract` shape), 2,000 and 10,000, three interleaved rounds, `78f0f3b` against `b2c4eaa`, pages from copies of both printing each commit's dirty-page count. Linux: `perf stat -x, -e instructions:u,cycles:u,branch-misses:u` of the read probe pinned to one core (`taskset -c 2`), three rounds, `fd5ef10`, `b2c4eaa` and `04ccab3`; `run.clj --no-build --only db --impls nexis --n 10 --max-load 4 --pin 0-11` from snapshots of `fd5ef10` and `04ccab3`, base, head, base, head (load 0.5–1.4), and once from `05ed7a1` with `--impls nexis,datalevin`; all under the host's benchmark lease. |
| §3.37, §6 "A Var's load run with its call", "Calls of one or two arguments in place", "Inline caches at call sites" | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); shared with concurrent sessions | 2026-10-08, varcalls: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `19eb7cd` (before), with the load run with its call over `f277127`, and with the calls in place and the load run with `call2` over `a9a7cec` (five commits, not kept); `-Dopcodes=true` twins of each. Micro kit: `bb bench/micro/run.clj --rounds 5 --programs count,acc,fib,gcall,lc,lv,mv,mvc,kw,leaf,getnl,vnth,leaf1,vdestr,cbbase,cbsum,cbred,cb,lazy,lazyl,lazyf BEFORE AFTER` under `tools/heavy` (1 core), the loads in the text. Whole process: the `bench/compare` programs (prelude and body) under `/usr/bin/time -l`, three interleaved rounds; the §3.31 shapes at 3 M once each. The trace: `lldb` stepping one iteration of `leaf1.nx` from one `fnCountLeaf` entry to the next. |
| §3.38, §6 "x86-64 handlers without register saves" | Intel Core Ultra 9 185H, 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, governor `powersave`, as §3.15; babashka v1.13.224; and Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434); Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `b3370fb` (a source snapshot on the Linux host); both hosts shared with other sessions | 2026-10-08 19:24–22:52 MDT, x86: `bin/nexis` built by `zig build install -Doptimize=fast` from source snapshots of `8cd7499` (before, `e115f57`'s source) and of `3065544` (after) on the Linux host, and with `--prefix DIR` at `8cd7499`, `13df08b` (the status word alone) and `3065544` on the M5, whose `13df08b` and `3065544` builds disassemble to the same instructions. Static sizes from `zig build codegen` at `8cd7499`, `13df08b` and `3065544`. Linux: `micro.sh`, `bb bench/micro/run.clj --counter perf --pin 2 --rounds 10 --programs count,fib,gcall,leaf,getnl,cbbase,cbsum,cb,lazy BEFORE AFTER`, twice, each in its own exclusive hold of the host's benchmark lease (load 0.9 → 1.2); `perfpairs.sh`, each run `taskset -c 2 /usr/bin/time -f %M perf stat -x, -e cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/br_misp_retired.indirect/u,cpu_core/ld_blocks.store_forward/u bin/nexis run P` over `prelude.nx` with each body, the builds interleaved, ten rounds (load 1.1 → 1.4); `run.clj --n 10 --max-load 4 --pin 0-11 --no-build --only lang --impls nexis,bb --workloads fib,destructure,vector-conj-nth,pipeline` from each snapshot, after, before, after, before (load 0.9 → 1.6; its report names the `zig` on the path, not the one that built). The `callLeaf` stall and the one-line trial of §6 from the Stage 0 profile at `fd5ef10` (`perf record -e cpu_core/cycles/upp` and `cpu_core/ld_blocks.store_forward/u`, five rounds). M5: `bb bench/micro/run.clj --rounds 5` over every program but those of other trees, and `--rounds 9` over the callback programs, under `tools/heavy` (1 core). |
| §3 "Durable commits", §6 "Fewer pages per durable commit", §3.15's durable note | Intel Core Ultra 9 185H, 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, ext4 on NVMe, governor `powersave`, as §3.15; Datalevin 1.1.0; and Apple M5, 10 cores, 32 GiB, macOS 27.0.1, APFS; Zig 0.17.0, ReleaseFast (`-Doptimize=fast`), emdb `b3370fb` | 2026-10-08 23:56 – 2026-10-09 00:25 MDT, durable: `bin/nexis` of `bd2cf5c`; on Linux under the `pup-bench` lease, processes pinned to CPUs 0–11, a probe of 300 durable commits per shape (`.nx` for Nextomic and `db/*`, a `dtlv exec` twin) over a copy of the `bench/compare` load, five runs of rounds with the shapes and systems alternating, the rounds whose `db/*` commit ran under 1.9 ms kept; `strace -f -c`, `strace -f -T` and `perf stat -e task-clock,page-faults` over 100 and 400 commits outside the lease; pages from a ReleaseFast build printing emdb's dirty-page count, not committed; Datalevin's writes from `strace -e pwrite64,writev,fdatasync` over 200 commits; the program table's Linux load from `bb bench/compare/run.clj --only db --impls nexis,datalevin --n 10 --max-load 4 --pin 0-11 --no-build`, its M5 rows from runs on one core at load 8–69 |
| §3.40, §6 "A width-consistent native boundary", "A native's result assembled in a temporary" and "The boundary's other widths" | Intel Core Ultra 9 185H, 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, governor `powersave`, as §3.15; babashka v1.13.224; and Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434); Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `b3370fb` (a source snapshot on the Linux host); both hosts shared with other sessions | 2026-10-09 00:00–01:50 MDT. x86: `bin/nexis` built by `zig build install -Doptimize=fast` from `git archive` snapshots of `bd2cf5c` (before) and `4cd8e90` (after) on the Linux host; `277a3b4`'s build there has the same `.text`, byte for byte. Linux: `micro.sh`, `bb bench/micro/run.clj --counter perf --pin 2 --rounds 10 --programs count,fib,gcall,leaf,getnl,vnth,leaf1,vdestr,cbbase,cbsum,cb,lazy BEFORE AFTER`, twice, each in its own hold of the host's benchmark lease (load 0.9 → 1.2); `pairs.sh`, each run `taskset -c 2 /usr/bin/time -f %M perf stat -x, -e cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/ld_blocks.store_forward/u bin/nexis run P` over `prelude.nx` with each body, the builds interleaved, ten rounds (load 1.0 → 1.3); `run.clj --n 10 --max-load 4 --pin 0-11 --no-build --only lang --impls nexis,bb --workloads destructure,vector-conj-nth,pipeline` from each snapshot, after, before, after, before (load 1.0 → 1.1). The blocked loads located with `perf mem record -t load --ldlat 4` (each sample's data source marks a load blocked on a store's data) and `perf record -e cpu_core/ld_blocks.store_forward/upp`; the dead ends from trial builds of the worktree, `perf stat` at two sizes per unit, three rounds. M5: `bb bench/micro/run.clj --rounds 5` over the same programs, twice, under `tools/heavy` (1 core; load 21.8 → 13.0), the builds `zig build install -Doptimize=fast --prefix DIR` at `bd2cf5c` and `277a3b4`. |
| §3.41, §6 "A native's result assembled in a temporary" and "A map literal's sort" | Intel Core Ultra 9 185H, 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, governor `powersave`, as §3.15; babashka v1.13.224; and Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434); Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `8463a21` (a source snapshot on the Linux host); both hosts shared with other sessions | 2026-10-09 04:40–05:50 MDT. x86: `bin/nexis` built by `zig build install -Doptimize=fast` on the Linux host from `git archive` snapshots of `1957422` (before) and of `1957422` with the stdlib and champ commits (after; a snapshot of the two commits themselves builds the same `.text` there, byte for byte). Linux: `micro.sh`, `bb bench/micro/run.clj --counter perf --pin 2 --rounds 10 --programs count,fib,gcall,leaf,getnl,vnth,leaf1,vdestr,cbbase,cbsum,cb,lazy BEFORE AFTER`, twice, each in its own hold of the host's benchmark lease (load 0.7 → 1.4); `pairs.sh`, each run `taskset -c 2 /usr/bin/time -f %M perf stat -x, -e cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/ld_blocks.store_forward/u bin/nexis run P` over `prelude.nx` with each body, the builds interleaved, ten rounds (load 0.9 → 1.7); `run.clj --n 10 --max-load 4 --pin 0-11 --no-build --only lang --impls nexis,bb --workloads destructure,vector-conj-nth,pipeline,map-build-read` from each snapshot, after, before, after, before (load 1.3 → 1.7). The natives-alone build and the dead ends from snapshots of the worktree, `perf stat` at two sizes per unit, three rounds, and the destructuring program three or four rounds; the blocked loads located with `perf record -e cpu_core/ld_blocks.store_forward/upp`. M5: `bb bench/micro/run.clj --rounds 5` over the same programs, twice, under `tools/heavy` (1 core; load 17.5 → 14.9, then 6.2 → 6.8), the builds `zig build install -Doptimize=fast --prefix DIR` of the same two trees. |
| §3.42, §6 "A leaf call's kind and arity in one test" and "A leaf's common case without a frame" | Intel Core Ultra 9 185H, 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, governor `powersave`, as §3.15; babashka v1.13.224; and Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434); Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `fb97dac` on the M5 and, on the Linux host, the source snapshot its revamp worktrees build against; both hosts shared with other sessions | 2026-10-10 15:18–16:08 MDT, varcall. `bin/nexis` built by `zig build install -Doptimize=fast` from `git archive` snapshots of `843a74e` (before), of `843a74e` with the stdlib commit (after), with the mask on top (the arity test), and with the `get`, `count` or `nth` change alone, on the Linux host; on the M5 with `--prefix DIR` from the worktree and a snapshot. Linux: `bb bench/micro/run.clj --counter perf --pin 2 --rounds 5 --programs count,fib,gcall,leaf,getnl,vnth,leaf1,vdestr,casek,mcall,kw,cbbase,cbsum,cb,lazy,xform BEFORE AFTER MASK` in one hold of the host's benchmark lease (load 3.6 → 3.6); `pairs.sh`, each run `taskset -c 2 /usr/bin/time -f %M perf stat -x, -e cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/ld_blocks.store_forward/u bin/nexis run P` over `prelude.nx` with each of the ten bodies, the builds interleaved, seven rounds (load 2.1 → 2.6), and the destructuring loop and the pipeline fifteen rounds; the single-change builds by `perf stat` with `cpu_core/machine_clears.count/u` and `cpu_core/machine_clears.memory_ordering/u`, three rounds; `run.clj --n 10 --max-load 4 --pin 0-11 --no-build --only lang --impls nexis,bb --workloads destructure,vector-conj-nth,pipeline,map-build-read` from each snapshot, after then before (load 1.5 → 2.9). M5: `bb bench/micro/run.clj --rounds 5` over every program under `tools/heavy` (1 core; load 5.8 → 6.1), the mask and frameless builds `--rounds 3` against the build before each; `m5pairs.sh`, each run `/usr/bin/time -l bin/nexis run P` over the same ten programs, the builds interleaved, five rounds (load 4.9 → 5.3), and `sort` fifteen. Dispatch and native counts from a `-Dopcodes=true` build of the after tree. |
| §6 "Levers pulled", the `cc935cc` figures of §3.11 | as §3.11 language and database rows, shared with concurrent builds (1-minute load average 5–15) | 2026-09-26: `bb bench/compare/run.clj --only db --n 10 --max-load 6 --no-build` over ReleaseFast binaries of the ws-durability branch (after) and of `cc935cc` (before), run one after the other; each run's third attempt, the first two having seen the load pass 6; ten rounds after a warm-up. The `bin/nexis` read figures: a probe program timing 10,000 of each operation over 10,000 entities with `nano-time`, three runs of each binary, alternating. `db_put_commit_scalar`: `zig build bench -Doptimize=ReleaseFast -- --filter db-integrated,nextomic`, three invocations at the branch head and two at `cc935cc`, alternating, the best median; §3.6's durable M5 figure is the `cc935cc` run's, and the branch head measured 7.2–8.9 ms under `NEXIS_DURABILITY=durable` at load 7 |
