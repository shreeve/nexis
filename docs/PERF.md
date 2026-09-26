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
file, cites a `measured` row here or is withdrawn (BENCH.md §1). No
row here is a same-machine comparison with Clojure; where a Clojure
figure appears it is an external reference and says so.

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
allocation-heavy throughput (a non-generational collector over the
process allocator). Only §3 turns any of these into a number.

---

## 2. Scorecard

The Clojure column is its design, not a measurement. "Measured" names
the §3 rows.

| # | Category | Clojure | nexis | Expected | Measured | Status |
|---|---|---|---|---|---|---|
| 1 | Value cell | every value an object reference; `Long`/`Double` boxed | 16-byte `{tag, payload}` cell, not NaN-boxed (`docs/VALUE.md` §1); nil, booleans, chars, fixnums, floats, keywords and symbols inline | smaller | — | not measured |
| 2 | Integer arithmetic | boxed `Long`; `^long` hints, `unchecked-*` | i48 fixnum immediate, promoting to bignum when a result leaves the range; `+ - * / quot mod < <= > >= == abs inc dec` inlined at their arity (`docs/COMPILER.md` §4.3) | ahead of idiomatic boxed code | §3.1 | measured |
| 3 | Float arithmetic | boxed `Double`; `^double` hints | the f64 bits in the payload word, NaN canonical | ahead of idiomatic boxed code | §3.1 | measured |
| 4 | Persistent map | HAMT | CHAMP (`docs/CHAMP.md`) | faster lookup, less memory | §3.2, §3.4, §3.8 | measured |
| 5 | Persistent set | HAMT | CHAMP | as #4 | §3.2, §3.4, §3.8 | measured |
| 6 | Persistent vector | 32-way trie + tail | 32-way trie + tail; `seq`/`rest`/`next`/`nthrest` an O(1) view | parity | §3.2, §3.4, §3.9 | measured |
| 7 | Persistent list | cons cells | cons cells | parity | §3.2 | measured |
| 8 | Hashing | Murmur3 | xxHash3-64; a heap value's hash cached in its header | faster on long bytes | §3.1 | measured |
| 9 | Keyword identity | interned, identity equality | intern id in the payload, identity equality | parity | §3.1 | measured |
| 10 | Transients | node-owner in-place edit | owner-token wrapper over the persistent operations (`docs/TRANSIENT.md`) | behind; same cost as persistent | §3.3 | measured |
| 11 | GC | generational (G1, ZGC) | precise non-moving mark-sweep (`docs/GC.md` §1) | behind under allocation churn | — | not measured |
| 12 | Allocator | TLAB bump pointer | `VM.heap` over the process allocator (`smp_allocator` in release builds) | behind on construction | §3.2 | measured |
| 13 | Dispatch | JIT inline caches | two-level switch on group and variant (`docs/VM.md` §8); no inline caches | behind at warm steady state | §3.8 | measured |
| 14 | Durable state | no stdlib primitive | emdb memory-mapped B+ tree (`docs/DB.md`) | lower latency than an out-of-process store | §3.6 | measured |
| 15 | Serialization | EDN text, Nippy | binary, LEB128 and ZigZag (`docs/CODEC.md`) | smaller, faster than text | §3.5 | measured |
| 16 | Concurrency tax | CAS and STM throughout | single isolate, single writer | none paid, by design | — | by design |
| 17 | SIMD | JIT autovectorization of primitive arrays | `nexis.simd` `sum`, `dot`, `scale` over typed vectors (`docs/TYPED_VECTOR.md`) | ahead on bulk numeric work | — | not measured |
| 18 | Startup | JVM start | native binary | far ahead | — | not measured |
| 19 | Compilation | C1/C2 JIT | bytecode, no specialization, no JIT | behind on sustained compute | §3.8 (nexis only) | not measured against Clojure |
| 20 | Comptime specialization | JIT inlining, escape analysis | CHAMP hashes an immediate key inline; the rest absent (§6) | — | §3.8 | partly absent |
| 21 | Datalog over datoms | Datomic peer and transactor | Nextomic in process over emdb (`docs/NEXTOMIC.md`) | — | §3.7 | measured |

---

## 3. Measured rows

Hosts: §3.1–§3.6 on an Apple M1; §3.6's second column, §3.7 and §3.8
on an Apple M5; §3.9 through `bin/nexis`. Every row is ReleaseFast.
Numbers from different machines are not comparable (BENCH.md §4). The
harness's own rows report the 30-sample median (BENCH.md §3) unless a
section says otherwise.

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
N=4096 does not accumulate across repetitions. "Process allocator" is
the configuration of the tree. "Pool" is a size-class pool under the
benchmark heaps (16 classes from 16 B to 4 KiB, LIFO free lists, slab
bump pointer); it is not in the tree, and its column is history, the
evidence for the §6 lever.

| Row | N | Process allocator | Pool (history) | Ratio |
|---|---:|---:|---:|---:|
| `list_cons_n` | 16 | 296 ns | 55 ns | 5.38× |
| `list_cons_n` | 256 | 4.35 μs | 858 ns | 5.07× |
| `list_cons_n` | 4096 | 72.0 μs | 18.3 μs | 3.94× |
| `vector_conj_n` | 16 | 701 ns | 215 ns | 3.26× |
| `vector_conj_n` | 256 | 12.3 μs | 4.30 μs | 2.86× |
| `vector_conj_n` | 4096 | 213 μs | 82.2 μs | 2.59× |
| `map_assoc_n` | 16 | 1.01 μs | 475 ns | 2.13× |
| `map_assoc_n` | 256 | 25.8 μs | 11.9 μs | 2.17× |
| `map_assoc_n` | 4096 | 620 μs | 345 μs | 1.80× |
| `set_conj_n` | 16 | 963 ns | 419 ns | 2.30× |
| `set_conj_n` | 256 | 24.6 μs | 10.7 μs | 2.30× |
| `set_conj_n` | 4096 | 586 μs | 319 μs | 1.84× |

The smaller the per-operation work, the more of it is the allocator:
list cons gains most, map assoc (hash, path copy, trie walk) least.
An external reference puts Clojure's `assoc` on a 4k-entry
`PersistentHashMap` at 100–300 ns after JIT warm-up; not a
same-machine comparison.

### 3.3 Transient construction

The same builds through `transient`, the `!` operations and
`persistent!`, N=4096.

| Row | Process allocator | Pool (history) |
|---|---:|---:|
| `transient_vector_conjbang_n` | 208 μs | 82.5 μs |
| `transient_map_assocbang_n` | 615 μs | 348 μs |
| `transient_set_conjbang_n` | 580 μs | 321 μs |

Transients cost what the persistent builds of §3.2 cost: a transient
is a wrapper that runs the persistent operation (`docs/TRANSIENT.md`),
not Clojure's in-place node edit.

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
warm-up; not same-machine comparisons.

### 3.5 Codec

| Row | Process allocator | Pool (history) |
|---|---:|---:|
| `codec_encode_fixnum` | 23 ns | 24 ns |
| `codec_decode_fixnum` | 4 ns | 4 ns |
| `codec_encode_map_n64` | 1.15 μs | 1.18 μs |
| `codec_decode_map_n64` | 6.18 μs | 5.44 μs |

Encoding writes into a presized buffer and does not allocate values;
decoding builds them, which is the only row the pool moved.

### 3.6 Durable refs (`db/*`)

| Row | Apple M1 | Apple M5 | Measures |
|---|---:|---:|---|
| `db_put_commit_scalar` | 6.15 ms | 6.00 ms | one put and a durable commit: the fsync, per commit, not per put |
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
spread across them in brackets; the two columns alternated in one
session, the tree before the planner and join work (`8548eda`) and
after it.

| Harness row | What | Before | After |
|---|---|---:|---:|
| `q_join3_by_dept_2k_rows` | 3-way join by department (`avet` seek → `vaet` → `eavt`), 2000 rows | 0.99 ms [0.99–1.10] | 0.94 ms [0.94–1.05] |
| `q_join3_by_age` | 3-way join by age (`avet` range → `eavt` → `eavt`), 851 rows | 2.20 ms [2.20–2.58] | 1.78 ms [1.78–2.06] |
| `q_count_hash_join` | `(count ?e)` by department (`aevt` scan, hash join), 667 rows | 0.34 ms [0.34–0.69] | 0.33 ms [0.33–0.39] |
| `q_join3_from_1_age` | 3-way join from one age, nested loop, 851 rows | 0.34 ms [0.34–0.76] | 0.32 ms [0.32–0.72] |
| `q_join3_from_3_ages` | from three ages, nested loop, 2602 rows | 1.09 ms [1.09–2.55] | 1.02 ms [1.02–2.87] |
| `q_join3_from_7_ages` | from seven ages, hash join on name and salary, 6259 rows | 2.74 ms [2.74–4.12] | 2.57 ms [2.57–6.04] |
| `q_chain_1000_clauses` | 1000-clause chain over a 10-entity chain, no row survives: planning | 113 ms [113–114] | 3.3 ms [3.3–4.5] |
| `q_chain_100_over_20k` | 100-clause chain over a 20k-entity chain, finding its ends, 19,900 rows | 431 ms [431–455] | 34.8 ms [34.8–36.4] |
| `q_chain_100_find_all_over_20k` | the same chain finding all 101 variables | 472 ms [472–529] | 72.2 ms [72.2–75.6] |
| `pull_many_star` | `pull-many [*]` over 20,000 entities, one read transaction | 9.98 ms [9.98–18.3] | 9.95 ms [9.95–10.3] |
| `pull_many_nested_ref_limit` | `pull-many` with a nested ref and `:limit`, 20,000 entities | 15.6 ms [15.6–21.4] | 15.5 ms [15.5–15.7] |
| `pull_reverse_ref_2k` | reverse-ref pull of one department's 2,000 employees | 0.096 ms [0.096–0.118] | 0.095 ms [0.095–0.096] |

Through `bin/nexis` over a chain of 100,000 entities, one query at a
time: a 300-clause chain finding its two ends took 80 s before and
0.67 s after, finding all 301 variables 1.5 s after; a 1000-clause
chain over a 10-entity chain took 118 ms before and 3.0 ms after. What
the rows before paid for: the planner re-estimated every pending
clause after each placement with a linear search of the bound
variables (O(n³) in clauses; `plan.choose` held nearly every sample),
and every join appended each row of a relation that kept every
variable bound so far, cell by cell (`Column.append` and the arena's
`memmove` of regrown columns held most of the rest). What the rows
after do is `docs/NEXTOMIC.md` §5: estimates kept until a clause's
variables change, dead variables dropped and output-only ones parked,
joins gathered column by column from the smaller side's index, and a
constant-prefix scan and its indexes kept for the query. A profile of
the chain after the change puts the time in the hash probe of the join
(`Relation.join`, `Cell.hash`) and nothing in the planner.

The result sets live on a heap over the process allocator. A profile
of the three-way join rows (`sample` on the ReleaseFast test binary)
puts about 30 % of the time in emdb's page search (`page.searchPage`,
`simd.compare`), 10 % in `Exec.scanInto` and about 5 % in decoding
string values out of keys; the rest is relation building and the
arena. Debug builds under the testing allocator are an order of
magnitude slower and are not measurements.

### 3.8 Dispatch and lookup, Apple M5

Before/after pairs for two changes: `vm` (the hot groups resolve
operands through the fetched frame; the collection check follows only
an instruction that could allocate, `docs/VM.md` §8, §9) and `champ`
(an immediate key hashes inline, `docs/CHAMP.md` §5.1). Best of five
invocations of the 30-sample median, spread in brackets. The `vm`
rows run a routine compiled once on one VM, so a sample is the
dispatch loop alone, 10,000 iterations.

| Row | Before | After | Change |
|---|---:|---:|---|
| `vm_loop_10k` | 340.71 μs [340.7–344.4] | 265.12 μs [265.1–288.6] | `vm` |
| `vm_global_call_10k` (`(inc1 i)` through a Var) | 588.10 μs [588.1–600.3] | 469.73 μs [469.7–497.0] | `vm` |
| `vm_keyword_get_10k` (`(:k m)`, 12-entry map) | 665.51 μs [665.5–669.6] | 517.11 μs [517.1–536.1] | `vm` |
| `eval_simple_loop` (compile and run a 100-iteration loop) | 5.99 μs [5.99–6.05] | 5.06 μs [5.06–5.40] | `vm` |
| `eval_arith`, `closure_create`, `compile_simple` | 1.41 μs, 1.02 μs, 550 ns | within noise | — |
| `map_get_n_hit` N=256 | 2.65 μs [2.65–2.69] | 2.10 μs [2.10–2.17] | `champ` |
| `map_get_n_hit` N=4096 | 60.66 μs [60.7–63.5] | 54.32 μs [54.3–54.9] | `champ`; 13.3 ns per get |
| `set_contains_n_hit` N=256 | 1.90 μs [1.90–1.93] | 1.19 μs [1.19–1.23] | `champ` |
| `set_contains_n_hit` N=4096 | 36.71 μs [36.7–37.2] | 28.17 μs [28.2–28.3] | `champ`; 6.9 ns per contains |
| `vector_nth_n_sequential` N=4096 | 2.89 μs | — | unchanged |

At the measured tree the counting loop compiled to 9 instructions per
iteration: 2.9 ns per instruction after the change, 3.8 ns before; a
global fn call (`var:load-var`, `call:call`, the callee's four
instructions, `call:return`) added 20 ns per iteration. The compiler
emits the same loop as 4 instructions per iteration (`bin/nexis
disasm`), so these rows need a rerun before a per-instruction figure
is quoted for the tree. A Var load is one read of the routine's
`var_table` entry and the Var's root (`docs/VM.md` §10.7).

### 3.9 Vector traversal through `bin/nexis`

Wall time of `bin/nexis run` (ReleaseFast) on two programs, before and
after `seq`, `rest`, `next` and `nthrest` of a vector became an O(1)
view (a list subkind over the vector, `docs/LIST.md`) instead of a
copy.

| Program | Before | After |
|---|---:|---:|
| `(loop [v (vec (range 20000))] (if (seq v) (recur (pop v)) v))` | 5.73 s | 0.11 s |
| 100 × `(reduce + (rest v))`, `v` of 100,000 elements | 0.43 s | 0.14 s |

### 3.10 Common forms through `bin/nexis`

What the compiler emits for common forms (instruction counts,
`docs/COMPILER.md` §4.8) and what that costs at run time, before and
after these changes to the code it emits: `let` aliases, forms for effect, returns in a function's tail, branching on
`and`, `or` and `not`, `is` as one helper call, `case` through one
lookup, overload dispatch on inlined compares, `assert` built at
expansion. Wall time inside one `bin/nexis run` of a probe program,
read with `nano-time` around each loop; the median of nine runs, the
two builds alternating, range in brackets.

| Loop | Before | After |
|---|---:|---:|
| 200k calls of a 10-keyword `case` with a default | 35.8 ms [35.4–38.4] | 27.6 ms [27.1–29.0] |
| 200k calls of a 10-int `case` with a default | 33.4 ms [31.0–35.4] | 24.6 ms [24.3–26.2] |
| 200k calls `(multi 1 2)` of a three-arity `defn` | 42.0 ms [38.7–43.5] | 32.4 ms [31.8–34.0] |
| 200k calls of a fn nesting `when-let` and `if-let` | 12.7 ms [12.2–14.1] | 10.2 ms [9.9–10.8] |
| 200k `(assert (pos? 1) "positive")` | 6.1 ms [6.0–6.6] | 5.7 ms [5.3–5.8] |
| 200k calls destructuring a vector and a map | 34.4 ms [33.2–36.5] | 32.9 ms [32.1–35.0] |
| 3 × `(count (for [x (range 100000)] (inc x)))` | 45.6 ms [44.3–48.7] | 45.3 ms [44.6–46.6] |
| 60k `is` assertions (`=`, a predicate, `thrown?`) through `run-tests` | 21.9 ms [21.5–23.5] | 22.3 ms [21.8–23.3] |

Before, an assertion inlined its whole report (17 instructions for
`(is (= ...))`); after, it is one call of a `nexis.test` helper (7),
making as many closure calls when it passes. Alone, 300k
`thrown?` assertions ran 113.7 ms before and 120.0 ms after (median of
five), the `fail!` call's operands being loaded before the throw. The
`compiler` and `vm` rows of `zig build bench` compile top-level forms
whose code these changes leave as it was; five alternating runs of
each build put every row's medians within each other's spread.

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
| startup (`-e`) | 4.70 ms | 11.3 ms | 0.41 | 6 MB | 30 MB |
| fib 30 | 101 ms | 104 ms | 0.97 | 6 MB | 77 MB |
| loop/recur, 1M | 37.1 ms | 58.0 ms | 0.64 | 6 MB | 83 MB |
| sort, 1M ints | 133 ms | 202 ms | 0.66 | 278 MB | 114 MB |
| map build and read, 1M | 854 ms | 827 ms | 1.03 | 331 MB | 192 MB |
| destructuring loop | 360 ms | 300 ms | 1.20 | 25 MB | 84 MB |
| map through transients, 1M | 821 ms | 595 ms | 1.38 | 331 MB | 178 MB |
| vector conj and nth, 1M | 177 ms | 77.6 ms | 2.29 | 504 MB | 127 MB |
| string build and split, 1 MB | 47.1 ms | 17.8 ms | 2.64 | 131 MB | 72 MB |
| map/filter/reduce over 1M maps | 162 ms | 37.1 ms | 4.36 | 498 MB | 212 MB |
| `frequencies` and `group-by`, 1M | 813 ms | 185 ms | 4.40 | 311 MB | 130 MB |

| Phase (100k entities × 5 attributes) | Nextomic | Datalevin 1.1 | ratio |
|---|---:|---:|---:|
| open an existing store | 106 μs | 12.5 ms | 0.01 |
| load, default commit | 1.64 s | 2.00 s | 0.82 |
| load, no per-commit flush | 702 ms | 1.90 s | 0.37 |
| 10k point lookups by a unique attribute | 21.1 ms | 31.9 ms | 0.66 |
| three-clause join, 20 × 1,000 rows | 12.6 ms | 31.0 ms | 0.41 |
| aggregate query | 18.0 ms | 93.8 ms | 0.19 |
| pull of 10k entities with a nested ref | 9.53 ms | 68.5 ms | 0.14 |
| 1,000 one-datom transactions, default commit | 4.02 s | 159 ms | 25.3 |
| 1,000 one-datom transactions, no per-commit flush | 39.9 ms | 58.4 ms | 0.68 |
| as-of and history query | 2.79 ms | no counterpart | — |
| store after the load (allocated) | 147 MB | 47 MB | 3.1 |

What the rows say:

- nexis starts in under 5 ms with a 6 MB resident set, matches
  babashka on calls and arithmetic (`fib`) and is ahead on tight loops
  and `sort`.
- It is behind on sequence pipelines (`map`/`filter`, eager here and
  lazy and chunked in babashka, `docs/BENCH.md` §12), on
  `frequencies`/`group-by` and transient maps, on vector `conj`/`nth`
  and on string splitting, and it holds 2–4× the memory on
  collections of a million elements: the collector's policy and the
  16-byte value cell show there.
- Nextomic is ahead of Datalevin on opening, loading, lookups, joins,
  aggregates and pull.
- The default-commit transaction row compares different guarantees:
  a Nextomic commit asks the drive to empty its write cache
  (`F_FULLFSYNC`, twice), Datalevin's does not (`docs/BENCH.md` §12).
  With the per-commit flush off in both, Nextomic is ahead. A
  durable commit per small transaction is the cost to lower (group
  commit, or a WAL); §6.
- The store is 3.1× Datalevin's. Half of it is the four history
  indexes and the txlog, which Datalevin does not keep; the table below
  has the rest. Writing each tree in plain key order leaves every
  leaf half full under emdb's splits: 198 MB, 4.3× (the "before"
  column, `docs/NEXTOMIC.md` §2.5).

Where the store's bytes go after the load (both commit modes give the
same trees): entries, key and value bytes, leaf pages, the share of
the leaves the entries fill, and the tree's pages in MB.

| tree | entries | key B | value B | leaves before → after | fill before → after | MB before → after |
|---|---:|---:|---:|---:|---:|---:|
| `nx/eavt` | 500,267 | 10.1 M | 3.0 M | 2,252 → 1,317 | 0.50 → 0.85 | 37.0 → 21.6 |
| `nx/aevt` | 500,267 | 10.1 M | 3.0 M | 2,053 → 1,577 | 0.55 → 0.71 | 33.7 → 25.9 |
| `nx/avet` | 200,231 | 4.3 M | 1.2 M | 898 → 757 | 0.52 → 0.61 | 14.8 → 12.5 |
| `nx/vaet` | 100,000 | 1.6 M | 0.6 M | 324 → 329 | 0.60 → 0.59 | 5.3 → 5.4 |
| `nx/eavt-h` | 500,267 | 13.1 M | 0 | 2,252 → 1,317 | 0.50 → 0.85 | 37.0 → 21.6 |
| `nx/aevt-h` | 500,267 | 13.1 M | 0 | 2,053 → 1,577 | 0.55 → 0.71 | 33.7 → 25.9 |
| `nx/avet-h` | 200,231 | 5.5 M | 0 | 898 → 757 | 0.52 → 0.61 | 14.8 → 12.5 |
| `nx/vaet-h` | 100,000 | 2.2 M | 0 | 324 → 329 | 0.60 → 0.59 | 5.3 → 5.4 |
| `nx/txlog` | 103 | 618 | 9.3 M | 600 overflow pages | — | 9.9 → 9.9 |
| all trees | | | | | | 191.4 → 140.7 |

Keys are already compact (6-byte `e` and `t`, 4-byte `a`); emdb adds
10 bytes per entry. EAVT fills best because each transaction writes
5,000 of its keys into one gap; AEVT's five gaps take 1,000 each and
fill less; AVET's and VAET's keys scatter over many small gaps, which
fill as random inserts do. A store of 20,000 entities with a 282-byte
string each (an out-of-line value, `docs/NEXTOMIC.md` §2.2) went from
56.0 MB of trees to 29.6 MB, the payload leaving the current EAVT row
(18.6 MB → 3.6 MB), and to 70.3 MB from 92.4 MB after every string was
replaced once.

## 6. Levers and dead ends

Each lever is a measured change: a before/after from `zig build bench`
(or a §3.9-style wall-time pair) or it does not land.

**Rows that do not exist.**

- A JVM Clojure column beside §3.11's babashka one (no JVM Clojure on
  the measuring host); every JVM Clojure figure here is external.
- Garbage-collection rows: steady-state allocation pressure, pause
  times.
- Allocated bytes for a fixed workload (scorecard #1); §3.11 has peak
  RSS per workload.
- A cold-cache random-access `nth` row beside §3.4's sequential one.
- `nexis.simd` and typed-vector rows (scorecard #17).
- Reruns: §3.1–§3.6 on the machine of §3.7–§3.8, with the emdb
  revision, to settle §3.6's 17×; §3.8's `vm` rows against the
  compiler's shorter loop.

**Levers not built.**

- **Store size** (§3.11, 3.1× Datalevin). A history index that holds
  only facts no longer current, with `as-of` and `history` merging it
  with the current index, would drop half the index pages of an
  append-mostly store; the readers are `nextomic/db.zig` and
  `query/plan.zig`. A transaction that writes less than a leaf's worth
  of keys into a gap (every one-datom transaction, and VAET's and
  AVET's scattered keys) still leaves a half-full leaf behind: emdb
  splits in half unless the key is the leaf's last, and a split at the
  insert point after a run of adjacent inserts would fill such leaves
  too, an engine change Nextomic does not ask for. Shorter integers
  (a variable-width `t` in current values and in `top`) would save
  about 5 % and change every key and value reader. The txlog repeats
  an out-of-line value's payload for its assertion and its
  retraction; referring to EAVT-h instead would drop most of a
  text-heavy store's log.

- **The durable commit of a small transaction.** A default Nextomic
  commit is two `F_FULLFSYNC` calls, about 4 ms, so 1,000 one-datom
  transactions take 4 s where Datalevin's weaker default takes 159 ms
  (§3.11). Group commit, several transactions under one flush, keeps
  the guarantee and divides the cost; the measurement is §3.11's
  `tx-1k-durable` row.
- **Memory on large collections.** §3.11's million-element rows hold
  2–4× babashka's resident set: the 16-byte value cell, non-moving
  mark-sweep over the process allocator, and eager intermediate
  results. The size-class pool below and a collection trigger that
  follows the live set are the levers.
- **`frequencies`, `group-by`, transient maps, `conj`/`nth` on
  vectors, string splitting** (§3.11, 2.3–4.4× behind babashka):
  each is a native or `core.nx` path to profile before changing.

- **A size-class pool under `VM.heap`.** The heap allocates every
  block from the process allocator. The pool the bench carried built
  lists 3.94×, vectors 2.59×, maps 1.80× and sets 1.84× faster at
  N=4096 and decoded maps 1.14× faster (§3.2, §3.3, §3.5); the runtime
  never used it. Under `VM.heap` it needs empty-slab reclamation, so a
  long REPL session gives memory back, and a before/after on the
  runtime's own heap.
- **Generational collection**: a nursery and write barriers, so
  short-lived path copies cost O(survivors) (`docs/GC.md` §1).
- **Opcode specialization**, and then **inline caches at call sites**.
- **Comptime specialization** beyond CHAMP's inline immediate hash:
  `(reduce + xs)` over fixnums, `equal` by kind pair.
- **Node-owner in-place-edit transients**: the source of Clojure's
  transient speedup; nexis's transients are wrappers (§3.3).
- **A smaller heap header** for small objects.
- **A single-key read path for durable refs** that skips the general
  transaction scaffolding.
- **Forwarding single-use `let` bindings into a call block**: `(let [x
  (f)] (g x))` computes `x` into its slot and moves it into `g`'s
  block; computing it into the block directly saves the move for each
  binding used once, as an argument, by the body's call.
- **A compare-and-branch opcode**: an `if` on `(< i n)` is `cmp:lt`
  into a slot and `jump:if-false` on it; a fused form halves every
  loop test and every `case` clause (§3.10). It is a new instruction
  (VM.md §10), so it needs the encoding's amendment.

**Dead ends, measured and reverted** (hosts of §3.7 and §3.8):

- *Keeping the run loop's frame pointer across instructions*, the
  fetch re-deriving it only after a group that can change `frames`:
  `vm_loop_10k` 267 → 314 μs in one run and within noise in three
  more. The loads it saves cost less than what the loop-carried
  pointer costs the register allocator.
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
kept with a caveat. §3.7 and §3.8 report the best of five invocations
of the harness's median; §3.9 reports wall time; every other §3 row
is one invocation's 30-sample median.

---

## 10. Cross-references

- `docs/BENCH.md` — method, harness, reporting rules.
- `docs/VALUE.md` §1 — the value cell.
- `docs/CHAMP.md`, `docs/VECTOR.md`, `docs/LIST.md`,
  `docs/TRANSIENT.md` — the collections measured in §3.2–§3.4.
- `docs/GC.md` — the collector.
- `docs/DB.md`, `docs/CODEC.md`, `docs/NEXTOMIC.md` — §3.5–§3.7.
- `docs/VM.md` §8, §9 — the dispatch loop of §3.8.

---

## 11. Measurement provenance

| Rows | Host | Run |
|---|---|---|
| §3.1–§3.5, §3.6 M1 column | Apple M1, macOS, Zig 0.16.0, ReleaseFast | 2026-04-19; `src/bench.zig` + `bench/main.zig`, 30 samples of ≥50 ms each. The two columns of §3.2, §3.3 and §3.5 are the benchmark heaps over the process allocator and over the size-class pool, since deleted. §3.1, §3.4 and §3.6 allocate nothing from the heap in their timed bodies |
| §3.6 M5 column, §3.8 | Apple M5, 32 GiB, macOS 26.6, Zig 0.16.0, ReleaseFast, idle | `zig build bench -Doptimize=ReleaseFast`, five invocations per state of the tree, the best median with the spread; "before" is the tree at `739d24f`, "after" the `vm` and `champ` commits named in the table. That run had the pool under the benchmark heaps; its construction and codec-decode rows are dropped as pool figures. The `vm`, `compiler`, lookup and `db` rows do not allocate from the pool |
| §3.7 | Apple M5, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds (load average 6–20) | revamp, 2026-09-25: `nexis-bench --filter nextomic` built by `zig build bench -Doptimize=ReleaseFast` from `bench/nextomic.zig` at the ws-planner head over the `src/` of `8548eda` (before) and of the ws-planner head (after), five invocations of each, alternating, the best median with the spread; the `bin/nexis` figures are one run each of a probe program timing `d/q` with `nano-time`, before at `b8c17a1` |
| §3.9 | not recorded | revamp, 2026-09-25, ReleaseFast `bin/nexis run`, at the merge of the vector-view change (`7f44db5`) |
| §3.10 | Apple M5, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds | revamp, 2026-09-25: `zig build install -Doptimize=ReleaseFast` at `c4413b1` (before) and at the ws-codegen branch head (after); the probe program run nine times per build, alternating, each loop timed with `nano-time`; the `thrown?` figure a separate program, five runs per build |
| §3.11 | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224, Datalevin 1.1.0 | 2026-09-26: `bb bench/compare/run.clj --n 10 --max-load 4` at `72d8312` (`main` at `f827775` with the harness); ten rounds after a discarded warm-up (startup thirty), each workload started below a load average of 4 and repeated if the load rose past it; raw results kept with the run (`results.json`). The store row: `bb bench/compare/run.clj --only db --n 10 --max-load 6` at the ws-storesize head, the load staying under 6 on the second attempt; the same run at `cc935cc` gave 198 MB (three attempts, the load past 6 in each), and no phase row moved outside its spread between the two |
| §3.11 per-tree table | Apple M5, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds | 2026-09-26: `nexis-load.nx STORE nosync` and `durable` built by `cc935cc` (before) and the ws-storesize head (after), read by a read-only program over emdb's `treeStat` and a cursor walk of each tree; fill counts 10 bytes of pointer and node header per entry over 16,352 usable bytes a leaf. The out-of-line rows: 20,000 `:doc/body` strings of 282 bytes, 1,000 per transaction with `:sync :none`, then each replaced once |
