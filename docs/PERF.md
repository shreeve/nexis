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
allocation-heavy throughput (a non-generational collector, no bump
allocation). Only §3 turns any of these into a number.

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
| 10 | Transients | node-owner in-place edit | node-owner in-place edit, the token in an internal node's header (`docs/TRANSIENT.md`) | parity | §3.3 | measured |
| 11 | GC | generational (G1, ZGC) | precise non-moving mark-sweep (`docs/GC.md` §1) | behind under allocation churn | — | not measured |
| 12 | Allocator | TLAB bump pointer | `VM.heap` over size-class slabs with free lists, no per-block prefix (`docs/HEAP.md` §2) | behind on construction | §3.2 | measured |
| 13 | Dispatch | JIT inline caches | threaded code: each handler tail-calls the next through a table indexed by opcode, the hot variants with handlers of their own (`docs/VM.md` §8); no inline caches | behind at warm steady state | §3.8, §3.12, §3.13 | measured |
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

Hosts: §3.1, §3.4's table and §3.6 on an Apple M1; §3.2, §3.3, §3.5,
§3.6's second column, §3.7, §3.8, §3.12, §3.13 and §3.14 on an
Apple M5;
§3.9 through `bin/nexis`. Every row is ReleaseFast.
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
N=4096 does not accumulate across repetitions. Apple M5; before is the
tree at `cc935cc`, every block from the process allocator; after is
the size-class slabs, tail claims and inline immediate keys
(`docs/HEAP.md` §2, `docs/VECTOR.md` §2, `docs/CHAMP.md` §6.5). The
median of three invocations' 30-sample medians, the two alternating,
the three in brackets. Provenance: §11.

| Row | N | Before | After | Ratio |
|---|---:|---:|---:|---:|
| `list_cons_n` | 16 | 270 ns [267–271] | 130 ns [128–130] | 2.08× |
| `list_cons_n` | 256 | 3.89 μs [3.88–3.95] | 1.44 μs [1.40–1.44] | 2.70× |
| `list_cons_n` | 4096 | 62.8 μs [62.5–63.3] | 21.2 μs [20.9–21.4] | 2.96× |
| `vector_conj_n` | 16 | 648 ns [648–658] | 212 ns [211–213] | 3.05× |
| `vector_conj_n` | 256 | 10.9 μs [10.9–11.6] | 2.31 μs [2.31–2.34] | 4.71× |
| `vector_conj_n` | 4096 | 185 μs [183–188] | 36.5 μs [36.1–36.9] | 5.06× |
| `map_assoc_n` | 16 | 811 ns [809–850] | 710 ns [709–710] | 1.14× |
| `map_assoc_n` | 256 | 24.9 μs [24.9–25.1] | 15.3 μs [15.3–15.3] | 1.63× |
| `map_assoc_n` | 4096 | 600 μs [598–611] | 406 μs [388–408] | 1.48× |
| `set_conj_n` | 16 | 746 ns [739–752] | 654 ns [651–659] | 1.14× |
| `set_conj_n` | 256 | 23.6 μs [23.4–24.2] | 12.8 μs [12.8–12.8] | 1.84× |
| `set_conj_n` | 4096 | 558 μs [556–571] | 340 μs [332–770] | 1.64× |

The smaller the per-operation work, the more of it is the allocator:
list cons gains from the slabs alone, vector conj also from claiming
its tail's next slot instead of copying the tail, map assoc (hash,
path copy, trie walk) least. A fresh heap takes its first slabs from
those an ended heap left (`docs/HEAP.md` §2); without that pool the
N=16 rows measure mapping them. An external reference puts Clojure's
`assoc` on a 4k-entry `PersistentHashMap` at 100–300 ns after JIT
warm-up; not a same-machine comparison.

### 3.3 Transient construction

The same builds through `transient`, the `!` operations and
`persistent!`, measured as §3.2. Before, a transient ran the
persistent operation under a wrapper; after, it edits the nodes it
owns in place (`docs/TRANSIENT.md` §1).

| Row | N | Before | After | Ratio |
|---|---:|---:|---:|---:|
| `transient_vector_conjbang_n` | 16 | 661 ns [659–691] | 140 ns [139–172] | 4.73× |
| `transient_vector_conjbang_n` | 256 | 11.0 μs [10.9–11.5] | 730 ns [729–732] | 15.0× |
| `transient_vector_conjbang_n` | 4096 | 187 μs [186–196] | 9.90 μs [9.66–11.7] | 18.9× |
| `transient_map_assocbang_n` | 16 | 840 ns [837–879] | 496 ns [492–549] | 1.69× |
| `transient_map_assocbang_n` | 256 | 26.0 μs [25.0–26.2] | 7.25 μs [7.21–7.86] | 3.58× |
| `transient_map_assocbang_n` | 4096 | 613 μs [611–664] | 156 μs [144–173] | 3.92× |
| `transient_set_conjbang_n` | 16 | 771 ns [768–803] | 473 ns [468–475] | 1.63× |
| `transient_set_conjbang_n` | 256 | 24.9 μs [24.1–25.1] | 6.71 μs [6.69–7.72] | 3.72× |
| `transient_set_conjbang_n` | 4096 | 565 μs [562–611] | 127 μs [127–152] | 4.46× |

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
does not exist. On the M5, measured as §3.2, the slabs leave every
lookup row within its spread (N=4096: 2.91 → 2.92 μs, 40.1 → 40.1 μs,
30.0 → 29.8 μs). External references put Clojure's 4k-entry
`PersistentHashMap` get at 25–40 ns and `nth` at 2–4 ns after JIT
warm-up; not same-machine comparisons.

### 3.5 Codec

Apple M5, measured as §3.2.

| Row | Before | After |
|---|---:|---:|
| `codec_encode_fixnum` | 22 ns [21–22] | 21 ns [21–25] |
| `codec_decode_fixnum` | 7 ns [0–7] | 8 ns [8–8] |
| `codec_encode_map_n64` | 682 ns [671–685] | 686 ns [685–747] |
| `codec_decode_map_n64` | 6.43 μs [6.26–6.53] | 4.62 μs [4.53–4.62] |

Encoding writes into a presized buffer and does not allocate values;
decoding builds them, which is the only row the slabs move.

### 3.6 Durable refs (`db/*`)

| Row | Apple M1 | Apple M5 | Measures |
|---|---:|---:|---|
| `db_put_commit_scalar` | — | 330 ns | one put and a commit in the default durability, `:commit`: no sync (`docs/DB.md` §3.3) |
| `db_put_commit_scalar`, `NEXIS_DURABILITY=durable` | 6.15 ms | 6.00 ms | one put and a durable commit: two `F_FULLFSYNC`, per commit, not per put |
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
disasm`); §3.12 reruns these rows on that code. A Var load is one read of the routine's
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
| startup (`-e`) | 4.77 ms | 11.5 ms | 0.41 | 6 MB | 30 MB |
| loop/recur, 1M | 13.5 ms | 57.6 ms | 0.23 | 6 MB | 83 MB |
| sort, 1M ints | 83.5 ms | 202 ms | 0.41 | 188 MB | 114 MB |
| fib 30 | 47.7 ms | 103 ms | 0.47 | 6 MB | 77 MB |
| map through transients, 1M | 302 ms | 646 ms | 0.47 | 156 MB | 178 MB |
| `frequencies` and `group-by`, 1M | 88.1 ms | 185 ms | 0.48 | 97 MB | 130 MB |
| destructuring loop | 188 ms | 301 ms | 0.62 | 24 MB | 84 MB |
| map build and read, 1M | 674 ms | 1.03 s | 0.65 | 175 MB | 193 MB |
| vector conj and nth, 1M | 57.2 ms | 77.2 ms | 0.74 | 100 MB | 126 MB |
| string build and split, 1 MB | 13.7 ms | 17.7 ms | 0.78 | 35 MB | 72 MB |
| map/filter/reduce over 1M maps | 48.8 ms | 42.5 ms | 1.15 | 238 MB | 212 MB |

| Phase (100k entities × 5 attributes) | Nextomic | Datalevin 1.1 | ratio |
|---|---:|---:|---:|
| open an existing store | 130 μs | 13.9 ms | 0.01 |
| create a store | 565 μs | 19.8 ms | 0.03 |
| load, default commit | 665 ms | 2.29 s | 0.29 |
| load, no per-commit flush | 750 ms | 2.23 s | 0.34 |
| 10k point lookups by a unique attribute | 12.0 ms | 35.8 ms | 0.33 |
| three-clause join, 20 × 1,000 rows | 12.5 ms | 35.9 ms | 0.35 |
| aggregate query | 20.3 ms | 137 ms | 0.15 |
| pull of 10k entities with a nested ref | 9.43 ms | 78.8 ms | 0.12 |
| 1,000 one-datom transactions, default commit | 19.4 ms | 171 ms | 0.11 |
| 1,000 one-datom transactions, no per-commit flush | 23.7 ms | 63.0 ms | 0.38 |
| as-of and history query | 2.23 ms | no counterpart | — |
| store after the load (allocated) | 152 MB | 46 MB | 3.3 |

The tree at `cc935cc`, where every default commit synced and every
read began its own transaction, measured 3.42 s for the default-commit
transactions, 1.64 s for the default-commit load and 24.6 ms for the
lookups under the same harness (§6 "Levers pulled", §11).

What the rows say:

- nexis starts in under 5 ms with a 6 MB resident set and is ahead of
  babashka on every row but one: 2–4× on loops, calls (`fib`), `sort`,
  transient maps and `frequencies`/`group-by`, 1.3–1.6× on
  destructuring, the map build, vector `conj`/`nth` and string
  splitting.
- The pipeline (`map`/`filter`/`reduce` over a million maps) is 1.15×
  babashka's in this table and 0.79× in §3.13's. Its sequences are eager here, lazy and chunked in
  babashka (`docs/BENCH.md` §12); no collection runs in its timed
  phase, whose cost was the calls each element makes (§3.13). Its
  resident set and `sort`'s are the two above babashka's here; §3.14
  takes the pipeline's under it, 195 MB against 212 MB, and leaves
  `sort` the one row that holds more.
- Nextomic is ahead of Datalevin on every phase: creating, opening,
  loading, lookups, joins, aggregates, pull and small transactions.
- The default-commit rows compare different guarantees. A default
  Nextomic commit (`:commit`, `docs/DB.md` §3.3) syncs nothing: it is
  atomic and survives a crash of the process, and the file is synced
  once at `release` and at the end of the program, outside the timed
  phase. Datalevin's calls `fsync`, which on macOS does not empty the
  drive's cache (`docs/BENCH.md` §12). A Nextomic connection opened
  `{:durability :durable}` syncs each commit, two `F_FULLFSYNC`, and
  pays 3.42 s for the 1,000 transactions. The no-flush rows include
  one sync at the end in both systems.
- The store is 3.3× Datalevin's. Half of it is the four history
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

**Sequences and strings.** Three of the rows above rerun on the tree
with eager sequences built as vector views, direct leaf callbacks,
`nthnext` destructuring, and the one-pass string natives (`LIST.md`
§1, `STRING.md` §3), against the same tree before them; before and
after are separate runs under different load (provenance §11), so the
instructions retired in the timed phase (`/usr/bin/time -l`, the
setup's subtracted, median of five or seven) are the steadier figure.

| Workload | nexis before | nexis after | babashka | ratio after | RSS before → after | instructions, timed phase |
|---|---:|---:|---:|---:|---:|---:|
| map/filter/reduce over 1M maps | 174 ms | 78.7 ms | 39.9 ms | 1.97 | 500 → 333 MB | 3.30 G → 1.98 G |
| string build and split, 1 MB | 50.8 ms | 30.5 ms | 22.6 ms | 1.35 | 133 → 47 MB | 1.23 G → 0.66 G |
| destructuring loop | 358 ms | 372 ms | 309 ms | 1.20 | 25 → 25 MB | 10.63 G → 10.30 G |

The pipeline's remaining cost was the calls each element makes
(§3.13; no collection runs in its timed phase); the destructuring
loop's is the VM's calls and the two literals it allocates per
iteration.

**Collections and the heap.** The collection rows rerun on the tree
with the size-class slabs, in-place transients, native `frequencies`
and `group-by`, vector tail claims and inline immediate keys
(`docs/HEAP.md` §2, `docs/TRANSIENT.md` §1, `docs/VECTOR.md` §2),
against `main` at the same point without them (`f84ab80`, which has
the sequence, string and dispatch work); one run of ten rounds each,
the two runs back to back under the same load (provenance §11).

| Workload | nexis before | nexis after | babashka | ratio after | RSS before → after | bb RSS |
|---|---:|---:|---:|---:|---:|---:|
| map build and read, 1M | 1.14 s | 757 ms | 1.07 s | 0.70 | 188 → 175 MB | 193 MB |
| map through transients, 1M | 1.05 s | 307 ms | 647 ms | 0.47 | 188 → 156 MB | 178 MB |
| vector conj and nth, 1M | 145 ms | 64.7 ms | 86.3 ms | 0.75 | 461 → 150 MB | 126 MB |
| `frequencies` and `group-by`, 1M | 797 ms | 94.9 ms | 205 ms | 0.46 | 140 → 97 MB | 133 MB |
| map/filter/reduce over 1M maps | 49.9 ms | 52.6 ms | 45.2 ms | 1.16 | 283 → 238 MB | 212 MB |
| sort, 1M ints | 98.9 ms | 94.2 ms | 223 ms | 0.42 | 183 → 188 MB | 114 MB |

A map built persistently still marks its whole live set at every
cycle (§6, the collector's trigger). The vector row's 150 MB was
measured without a safe point in `callValue` of a native
(`docs/GC.md` §7): `reduce`, a native calling a native, kept the
garbage of a million persistent `conj`s resident until it returned.
The main table's run, with it, holds 100 MB.

### 3.12 Threaded dispatch and direct calls, Apple M5

Before and after the threaded dispatch, the hot handlers and the
direct call paths (`docs/VM.md` §6, §8): the tree at `968aa77` and at
the ws-dispatch head, one ReleaseFast build of each. Provenance: §11.

The harness's rows: five invocations of `zig build bench --filter
vm,compiler` per build, alternating, the best 30-sample median with
the spread of the five.

| Row | Before | After |
|---|---:|---:|
| `vm_loop_10k` | 109.17 μs [109.2–125.2] | 53.03 μs [53.0–60.7] |
| `vm_global_call_10k` (`(inc1 i)` through a Var) | 287.97 μs [288.0–317.8] | 133.23 μs [133.2–148.6] |
| `vm_keyword_get_10k` (`(:k m)`, 12-entry map) | 321.28 μs [321.3–363.0] | 229.28 μs [229.3–252.1] |
| `eval_simple_loop` (compile and run a 100-iteration loop) | 2.73 μs [2.73–3.63] | 2.12 μs [2.12–2.41] |
| `eval_arith`, `closure_create`, `compile_simple` | 0.96 μs, 0.78 μs, 0.42 μs | within the spread |

The counting loop is 4 instructions per iteration, `cmp:lt`,
`jump:if-false`, `math:add` and `jump:jmp`, and 3 dispatches, the
comparison running its branch (`docs/VM.md` §8): 5.3 ns per iteration
after, 10.9 ns before. The `(inc1 i)` loop, 6 instructions and the
callee's 2, runs 13.3 ns per iteration after, 28.8 ns before.

Against babashka, `bench/compare/run.clj` (`docs/BENCH.md` §12): two
runs of ten rounds per build, before, after, before, after; each cell
is a run's median time inside the process, the first run then the
second.

| Workload | nexis before | nexis after | babashka | ratio after |
|---|---:|---:|---:|---:|
| fib 30 | 103, 103 ms | 47.6, 47.4 ms | 104, 102 ms | 0.46, 0.47 |
| loop/recur, 1M | 40.0, 40.3 ms | 14.2, 14.3 ms | 59.0, 59.7 ms | 0.24, 0.24 |
| destructuring loop | 375, 373 ms | 254, 237 ms | 324, 297 ms | 0.78, 0.80 |
| sort, 1M ints | 112, 105 ms | 98.0, 126 ms | 223, 321 ms | 0.44, 0.39 |
| map build and read, 1M | 1.41 s, 1.02 s | 1.06 s, 968 ms | 930, 892 ms | 1.14, 1.09 |
| map/filter/reduce over 1M maps | 105, 71.6 ms | 51.6, 65.2 ms | 45.4, 59.7 ms | 1.14, 1.09 |

nexis is ahead on calls (`fib`), loops, destructuring and `sort`, and
within about 10 % of babashka on the map build, whose remaining cost
is allocation and the collector (§3.11), and on the pipeline, whose
cost was its per-element calls (§3.13). Every answer matched in every
run. The destructuring loop still calls `+`
with five arguments through its Var and `get`, `nth`, `nthnext` and
`count` as natives; a native call costs a `var:load-var`, the moves
into its block and one `call:call`.

### 3.13 Calls from natives, Apple M5

Before and after four changes to what a sequence native pays per
element (`docs/VM.md` §6 "Repeated calls", §8, §10.3; `docs/LIST.md`
§1): a keyword or symbol callee looks itself up in place in
`call:call`; `map`, `filter`, `remove`, `keep` and `reduce` prepare
their callback once (`vm.Callback`); a vector or a list is stepped,
and a root pushed, inline in the native's loop; `+` of two fixnums,
`inc`, `dec`, `even?` and `odd?` of one compute inline. The tree at
`a712a24` and the ws-pipeline-calls head, one ReleaseFast build of
each. Provenance: §11.

Where the pipeline's timed phase went, in instructions retired
(`/usr/bin/time -l`, each stage's program minus the one before it,
median of five): the filter's closure call through `callValue` cost
about 190 instructions a row before its body ran; `(:group row)` in
that body, the general call path (the arguments copied, the overflow
snapshot, `callLookupIn`, a safe point), about 470; `even?` 130; and
the walk, the push of each kept row and the result about 180. No
collection runs in the phase: the setup's last cycle leaves 134 MB
live, and the phase allocates less than that before the next is due.

| Stage | Before | After |
|---|---:|---:|
| `(filter (fn [row] (even? (:group row))))`, 1M rows | 964 M | 683 M |
| `(map :score)`, 500k rows | 141 M | 94 M |
| `(map inc)`, 500k | 125 M | 64 M |
| `(reduce +)`, 500k | 107 M | 57 M |
| the timed phase | 1,338 M | 898 M |

Against babashka, `bench/compare/run.clj --n 10 --max-load 6
--no-build --workloads pipeline,fib,loop,destructure` (`docs/BENCH.md`
§12): two runs per build, after, before, after, before; each cell is
a run's median time inside the process, the first run then the
second, with the load average at each run's start.

| Workload | nexis before | nexis after | babashka | ratio before | ratio after |
|---|---:|---:|---:|---:|---:|
| map/filter/reduce over 1M maps | 49.6, 52.8 ms | 33.9, 33.7 ms | 42.5–47.3 ms | 1.16, 1.12 | 0.80, 0.79 |
| fib 30 | 46.7, 58.1 ms | 51.1, 46.9 ms | 102–125 ms | 0.46, 0.46 | 0.45, 0.46 |
| loop/recur, 1M | 13.4, 15.6 ms | 14.7, 13.4 ms | 57.9–65.1 ms | 0.23, 0.24 | 0.23, 0.22 |
| destructuring loop | 190, 204 ms | 208, 188 ms | 302–340 ms | 0.61, 0.62 | 0.61, 0.62 |
| load average at the start | 5.8, 4.1 | 14.2 (each workload waited for it to fall below 6), 4.8 | | | |

The pipeline's resident set is 238 MB both ways. The other rows move
with the load, babashka's with them, and their ratios do not move.
The harness's `vm` rows, five invocations of `zig build bench
-Doptimize=ReleaseFast -- --filter vm` per build, alternating, the
best 30-sample median with the spread of the five:

| Row | Before | After |
|---|---:|---:|
| `vm_loop_10k` | 56.53 μs [56.5–203.6] | 57.39 μs [57.4–99.7] |
| `vm_global_call_10k` | 143.55 μs [143.6–333.6] | 142.51 μs [142.5–161.0] |
| `vm_keyword_get_10k` (`(:k m)`, 12-entry map) | 230.92 μs [230.9–434.8] | 172.77 μs [172.8–199.7] |

What is left of the pipeline's phase is the closure body's six
dispatches per row (`var:load-var`, `mov:load-const`, `mov:move`, two
`call:call`, `call:return`; about a third of the samples in a
`sample` profile), the loop's entry and exit for each callback, and
the first touch of each row's map (`mapGet`, about an eighth).

### 3.14 The heap of the sequence natives, Apple M5

Where the pipeline's memory went, at `a712a24` (a build with a trace
of each cycle and of the heap at exit, not committed): the setup runs
four cycles, at 16, 34, 67 and 134 MB live, in 0.4, 2.2, 4.4–6.8 and
12.5–15.5 ms; only the first frees anything (358 blocks), and the
timed phase allocates 25 MB, less than the 134 MB the next cycle
waits for, so no cycle runs in it. Its peak resident set, 238 MB, was
the heap's 187 MB (1M maps of 128 bytes, the rows' vector, the
setup's `range` vector, garbage since its `mapv`, and the phase's
three result vectors), the root stack's 16.8 MB (the capacity the
`mapv` left it), the collector's gray worklist, 1.3 M entries
(10.4 MB: the `mapv`'s results on the root stack and every map a
vector's trace reached were queued), 6 MB for the process, and about
17 MB of malloc'd buffers freed but still resident (`range`'s list
and the growth steps of the two above). The phase's 1.34 G
instructions were its calls (§3.13); building its three results, a
push per value and a copy per leaf, was about 5 % of its profile.

Before (`a712a24`) and after this section's changes (§6 "Levers
pulled"), and against the tree they merge with (`8afd353`, §3.13's
changes), in instructions retired (`/usr/bin/time -l`, median of
five, the phase as the whole program minus its setup alone) and peak
resident set:

| Pipeline program | `a712a24` | `8afd353` | after |
|---|---:|---:|---:|
| setup (`mapv` over `range`), instructions | 2,127 M | 2,021 M | 1,984 M |
| timed phase, instructions | 1,349 M | 879 M | 884 M |
| setup alone, peak RSS | 213 MB | 212 MB | 170 MB |
| whole program, peak RSS | 238 MB | 238 MB | 195 MB |

Against babashka, `bench/compare/run.clj --n 10 --max-load 6
--no-build --workloads pipeline,map-build-read,map-transient,vector-conj-nth,sort,freq-group`
(`docs/BENCH.md` §12), four runs alternating the builds, after, main,
after, main; each cell is a run's median time inside the process, the
first run then the second. The `a712a24` column is one run before
them, its map-transient row measured after the load passed 6 in
each of three attempts.

| Workload | nexis `8afd353` | nexis after | babashka | ratio after | RSS `a712a24` → `8afd353` → after | bb RSS |
|---|---:|---:|---:|---:|---:|---:|
| map/filter/reduce over 1M maps | 33.4, 35.6 ms | 34.2, 34.4 ms | 42.3–46.7 ms | 0.80, 0.79 | 238 → 238 → 195 MB | 212 MB |
| `frequencies` and `group-by`, 1M | 80.5, 86.2 ms | 81.5, 81.0 ms | 180–198 ms | 0.45, 0.45 | 99 → 97 → 57 MB | 130–133 MB |
| map build and read, 1M | 519, 577 ms | 525, 535 ms | 800–895 ms | 0.64, 0.66 | 175 → 175 → 140 MB | 192 MB |
| map through transients, 1M | 283, 328 ms | 293, 300 ms | 580–644 ms | 0.47, 0.47 | 158 → 156 → 122 MB | 178 MB |
| sort, 1M ints | 81.5, 87.9 ms | 82.5, 88.2 ms | 198–231 ms | 0.42, 0.38 | 188 → 188 → 155 MB | 113–114 MB |
| vector conj and nth, 1M | 52.7, 56.9 ms | 51.6, 56.9 ms | 76.0–83.6 ms | 0.67, 0.68 | 101 → 100 → 65 MB | 126 MB |
| load average at the start | 3.1, 3.9 | 4.6, 3.8 | | | | |

Every answer matched in every run. The time of every row is the same
before and after within the runs' spread; every row's resident set
falls by 35–43 MB, the root stack's and the worklist's retained
capacity and the malloc'd buffers no longer there, and the pipeline's
is under babashka's. `sort` still holds more: it gathers its elements
into a malloc'd list and merge-sorts them through two more of pairs,
80 MB beside its input for a million (§6, "`sort`'s buffers").

The trigger (`docs/GC.md` §7), set by hand on the after build, five
runs each of the pipeline program, cycles and the phase's time:

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
  revision, to settle §3.6's 17×.

**Levers not built.**

- **Batched commits** (`docs/DB.md` §3.3 "No batching"): consecutive
  auto-transaction writes joined into one open emdb write transaction
  would save part of a `:commit` transaction's cost, about 18 μs in
  all (§3.11), at the price of holding the writer between natives. A `:durable` commit's two device flushes are the other
  cost left; group commit under one flush would divide it.
- **Store size** (§3.11, 3.3× Datalevin). A history index that holds
  only facts no longer current, with `as-of` and `history` merging it
  with the current index, would drop half the index pages of an
  append-mostly store; the readers are `nextomic/db.zig` and
  `query/plan.zig`. A transaction that writes less than a leaf's worth
  of keys into a gap (every one-datom transaction, and VAET's and
  AVET's scattered keys) still leaves a half-full leaf behind: emdb
  keeps an ascending run's position within one write transaction
  (`docs/NEXTOMIC.md` §2.5), so a gap that a stream of small
  transactions writes one key at a time splits in half each time. Shorter integers
  (a variable-width `t` in current values and in `top`) would save
  about 5 % and change every key and value reader. The txlog repeats
  an out-of-line value's payload for its assertion and its
  retraction; referring to EAVT-h instead would drop most of a
  text-heavy store's log.
- **The collector's trigger.** A cycle is due once the heap has
  allocated its live size again (100 %) or 16 MiB. A build that grows
  a large live set is marked at each doubling, about twice its final
  size in all; the pipeline's setup runs four cycles (§3.14) and its
  timed phase none. A lower growth brings a cycle into that phase and
  trades time for resident memory, a higher one or a higher floor
  changes neither (§3.14's trigger table); the remaining measurement
  is a program whose live set stays flat while it allocates.

- **`sort`'s buffers.** `sortImpl` gathers the elements into a
  malloc'd list (16 bytes each) and sorts `{key, val}` pairs through a
  scratch array of the same size (32 bytes each, twice), 80 MB for
  §3.11's million ints, all resident at the peak; `(vec sorted)` then
  gathers the result again. Sorting the values alone when there is no
  key function, and building the result in place (`Results`), would
  halve it; the measurement is §3.11's `sort` row with its RSS.
- **Generational collection**: a nursery and write barriers, so
  short-lived path copies cost O(survivors) (`docs/GC.md` §1).
- **Operand-specialized opcodes**, and then **inline caches at call
  sites**: the hot handlers test their operands' kinds at run time
  (`docs/VM.md` §8); an opcode per kind pair drops the tests at the
  cost of instruction rows.
- **`+` and `*` inlined at any arity**: `(+ a b x y z)` calls the
  native through its Var (the destructuring loop, §3.12), where a
  chain of `math:add` is the same left fold (`docs/COMPILER.md`
  §4.3).
- **Comptime specialization** beyond CHAMP's inline immediate hash:
  `(reduce + xs)` over fixnums, `equal` by kind pair.
- **A smaller heap header** for small objects.
- **A single-key read path for durable refs** that skips the general
  transaction scaffolding.
- **Forwarding single-use `let` bindings into a call block**: `(let [x
  (f)] (g x))` computes `x` into its slot and moves it into `g`'s
  block; computing it into the block directly saves the move for each
  binding used once, as an argument, by the body's call.
- **A keyword lookup instruction**: `(:k x)` with a constant keyword
  is `mov:load-const`, `mov:move` and `call:call`, three dispatches
  for what §3.13's in-place lookup does in one; one instruction
  naming the keyword constant and the operand would drop two, at the
  cost of an opcode (an amendment of VM.md §10).
- **A compare-and-branch instruction**: an `if` on `(< i n)` is
  `cmp:lt` into a slot and `jump:if-false` on it, which the dispatch
  runs as one (`docs/VM.md` §8, §3.12). One encoded instruction would
  also drop the slot write and a fetch, but two operands and a jump
  target do not fit it (VM.md §3), so it needs the encoding's
  amendment.

**Levers pulled.**

- *Commit without a sync by default* (`docs/DB.md` §3.3): §3.11's
  1,000 default-commit transactions 3.42 s → 17.7 ms, the
  default-commit load 1.64 s → 656 ms, `db_put_commit_scalar`
  6.00 ms → 330 ns. The file is synced once at close and exit.
- *A held read snapshot* (`docs/DB.md` §3.4): a Nextomic read reuses
  the file's last read transaction, twelve trees loaded, while no
  commit has passed it. §3.11's lookups 24.6 → 13.5 ms; through
  `bin/nexis`, 10,000 `(d/db conn)` 4.63 → 0.77 ms, `d/entity` plus
  one attribute 16.9 → 8.6 ms, `d/entid` by lookup ref 8.5 → 4.3 ms
  (§11). The query and pull rows of §3.7 each run one read and did
  not move outside their spread.
- *A safe point where a native calls a native* (`docs/GC.md` §7):
  `VM.callValue` checks the collector before it calls a non-closure,
  whose arguments are rooted. `(reduce conj [] xs)` over a million
  elements peaked at 15.5 MB live against 193 KB kept before and
  under 3× the kept set after (the `eval_pipeline` test); §3.11's
  vector row 150 → 100 MB and 64.7 → 57.2 ms.

- *Calls from natives* (§3.13): a keyword or symbol callee looking
  itself up in place in `call:call` (`docs/VM.md` §8), a sequence
  native's callback prepared once (`vm.Callback`, VM.md §6), a vector
  or list stepped and a root pushed inline in the native's loop, and
  `+`, `inc`, `dec`, `even?` and `odd?` on fixnums inline (VM.md
  §10.3). The pipeline's timed phase 1,338 M → 898 M instructions and
  49.6, 52.8 → 33.9, 33.7 ms against babashka's 42.5–47.3 ms, ratio
  1.16, 1.12 → 0.80, 0.79;
  `vm_keyword_get_10k` 230.9 → 172.8 μs. Each step alone, the phase's
  instructions and its median of ten alternating runs of the
  pipeline: the keyword lookup 1,343 → 1,142 M and 52.6 → 46.2 ms
  (load 18), the prepared callback 1,136 → 1,039 M and 47.4 →
  42.5 ms (load 3), the inline walk and push 1,043 → 938 M and 43.6 →
  40.3 ms (load 5), the arithmetic 951 → 874 M and 37.6 → 34.2 ms
  (load 7).
- *Marking in place, one root at a time* (`docs/GC.md` §4): the
  drain traces what a popped header's trace marks there and then,
  four levels deep, and `collect` drains after each root. The gray
  worklist the pipeline's setup grew to 1.3 M entries (10.4 MB, kept
  between cycles) stays at 17.
- *Results built in place* (`docs/LIST.md` §1, `docs/VECTOR.md` §5):
  `map`, `filter` and their kin, `mapv`, `filterv` and `range` write
  each value past the 32nd into the open tail of the vector they
  return, never into a buffer on the root stack (16.8 MB kept by the
  VM after the setup's `mapv`) or a malloc'd list (`range`'s, freed
  but resident). With the marking above: the pipeline 238 → 195 MB
  at the same time, `frequencies`/`group-by` 97 → 57 MB, the map build
  175 → 140 MB, transient maps 156 → 122 MB, `sort` 188 → 155 MB,
  vector `conj`/`nth` 100 → 65 MB (§3.14).
- *A built sequence walked as its vector* (`docs/LIST.md` §3,
  `viewCursor`): the pipeline's phase 1,327 → 1,253 M instructions on
  the tree before §3.13's changes, which stepped a list inline in the
  place.

**Dead ends, measured and reverted** (hosts of §3.7 and §3.8):

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
- *Hot handlers with a check-free fast path*: `mov:move`,
  `mov:load-const` and `var:load-var` testing their common operand
  kinds in one branch and handing everything else to the general
  handler. The pipeline's phase 876 → 854 M instructions, its median
  40.7 → 39.5 ms at a load of 17, inside the spread. The compiler
  inlines the general handler back and keeps the stack frame the fast
  path was meant to drop; a handler without one needs the slow path
  out of line, which a constant function pointer does not ensure.

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
| §3.1, §3.4's table, §3.6 M1 column | Apple M1, macOS, Zig 0.16.0, ReleaseFast | 2026-04-19; `src/bench.zig` + `bench/main.zig`, 30 samples of ≥50 ms each. These rows allocate nothing from the heap in their timed bodies |
| §3.2, §3.3, §3.4's M5 figures, §3.5 | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds (load average 4–7) | revamp, 2026-09-26, ws-collections: `nexis-bench --filter collection-construction,transient-construction,collection-lookup-update,codec`, built by `zig build bench -Doptimize=ReleaseFast` at `cc935cc` (before) and at the ws-collections head `5a1e9b4` (after); three invocations of each, alternating, the median of the three 30-sample medians with the three in brackets |
| §3.11 collections and the heap | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds | revamp, 2026-09-26, ws-collections: `bb bench/compare/run.clj --n 10 --max-load 6 --workloads map-build-read,map-transient,vector-conj-nth,freq-group,pipeline,sort,startup` with the `bin/nexis` of the ws-collections head `5a1e9b4` (after), then of `f84ab80` (before), load 3.7–4.8 at the starts and ends; each workload started below a load average of 6 and repeated if the load rose past it |
| §3.6 M5 column, §3.8 | Apple M5, 32 GiB, macOS 26.6, Zig 0.16.0, ReleaseFast, idle | `zig build bench -Doptimize=ReleaseFast`, five invocations per state of the tree, the best median with the spread; "before" is the tree at `739d24f`, "after" the `vm` and `champ` commits named in the table. That run had the pool under the benchmark heaps; its construction and codec-decode rows are dropped as pool figures. The `vm`, `compiler`, lookup and `db` rows do not allocate from the pool |
| §3.7 | Apple M5, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds (load average 6–20) | revamp, 2026-09-25: `nexis-bench --filter nextomic` built by `zig build bench -Doptimize=ReleaseFast` from `bench/nextomic.zig` at the ws-planner head over the `src/` of `8548eda` (before) and of the ws-planner head (after), five invocations of each, alternating, the best median with the spread; the `bin/nexis` figures are one run each of a probe program timing `d/q` with `nano-time`, before at `b8c17a1` |
| §3.9 | not recorded | revamp, 2026-09-25, ReleaseFast `bin/nexis run`, at the merge of the vector-view change (`7f44db5`) |
| §3.10 | Apple M5, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds | revamp, 2026-09-25: `zig build install -Doptimize=ReleaseFast` at `c4413b1` (before) and at the ws-codegen branch head (after); the probe program run nine times per build, alternating, each loop timed with `nano-time`; the `thrown?` figure a separate program, five runs per build |
| §3.11 language and database rows | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224, Datalevin 1.1.0; shared with concurrent builds (load average 4.1 at the start, 8.0 at the end) | 2026-09-26 17:25 MDT: `bb bench/compare/run.clj --n 10 --max-load 4` at `5440e80`; ten rounds after a discarded warm-up (startup thirty), the implementations alternating, each workload started below a load average of 4 and repeated if the load rose past it; every answer equal; raw results kept with the run (`results.json`) |
| §6 "Levers pulled", the `cc935cc` figures of §3.11 | the same host, shared with concurrent builds (1-minute load average 5–15) | 2026-09-26: `bb bench/compare/run.clj --only db --n 10 --max-load 6 --no-build` over ReleaseFast binaries of the ws-durability branch (after) and of `cc935cc` (before), run one after the other; each run's third attempt, the first two having seen the load pass 6; ten rounds after a warm-up. The `bin/nexis` read figures: a probe program timing 10,000 of each operation over 10,000 entities with `nano-time`, three runs of each binary, alternating. `db_put_commit_scalar`: `zig build bench -Doptimize=ReleaseFast -- --filter db-integrated,nextomic`, three invocations at the branch head and two at `cc935cc`, alternating, the best median; §3.6's durable M5 figure is the `cc935cc` run's, and the branch head measured 7.2–8.9 ms under `NEXIS_DURABILITY=durable` at load 7 |
| §3.11 sequences and strings | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds | revamp, 2026-09-26, ws-strseq: `bb bench/compare/run.clj --n 10 --workloads string-split,pipeline,destructure`, before at `cc935cc` (`--max-load 12`, load 27 falling to 8), after at `c0d6043` (`--max-load 6`); the instruction counts from `/usr/bin/time -l bin/nexis run` of each workload's program, five or seven runs per build, minus a run of its setup alone |
| §3.11 per-tree table | Apple M5, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds | 2026-09-26: `nexis-load.nx STORE nosync` and `durable` built by `cc935cc` (before) and the ws-storesize head (after), read by a read-only program over emdb's `treeStat` and a cursor walk of each tree; fill counts 10 bytes of pointer and node header per entry over 16,352 usable bytes a leaf. The out-of-line rows: 20,000 `:doc/body` strings of 282 bytes, 1,000 per transaction with `:sync :none`, then each replaced once |
| §3.12 | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds (load average 3–9) | revamp, 2026-09-26, ws-dispatch: `nexis-bench` and `bin/nexis` built at `968aa77` (before) and at `5f724d7` (after); `nexis-bench --filter vm,compiler` five times per build, alternating; `bb bench/compare/run.clj --n 10 --max-load 6 --no-build --workloads fib,loop,destructure,sort,map-build-read,pipeline` four times, the builds alternating, each run's report naming the tree's head since the binary was swapped in |
| §3.13, §6 "Calls from natives" | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds (load average 3–18) | 2026-09-27, ws-pipeline-calls: `bin/nexis` and `nexis-bench` built at `a712a24` (before) and at the branch head (after); `bb bench/compare/run.clj --n 10 --max-load 6 --no-build --workloads pipeline,fib,loop,destructure` four times, after, before, after, before, the binary swapped into one worktree, so each report names the branch head; `zig build bench -Doptimize=ReleaseFast -- --filter vm` five times per build, alternating; the instruction counts from `/usr/bin/time -l bin/nexis run` of the pipeline's program cut after each stage, median of five, the setup's own run subtracted; the per-step figures of §6 from each commit's build against the one before it, the phase timed with `nano-time` inside `bin/nexis run` of the pipeline program, ten runs each, alternating |
| §3.14, §6 "Marking in place", "Results built in place", "A built sequence walked as its vector" and their dead ends | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds (load average 3–16) | 2026-09-27/28, ws-pipeline-heap: `bin/nexis` built at `a712a24`, at `8afd353` (main with ws-pipeline-calls) and at the branch head; the cycle and heap figures from a build of `a712a24` with a trace printed at each cycle and at exit; `bb bench/compare/run.clj --n 10 --max-load 6 --no-build --workloads pipeline,map-build-read,map-transient,vector-conj-nth,sort,freq-group` once with `a712a24`, then four times, branch head and `8afd353` alternating, the binary swapped into the branch's worktree, so each report names the branch head; the instruction counts from `/usr/bin/time -l bin/nexis run` of the pipeline program and of its setup alone, five runs each, the median; the trigger table from a build reading the growth and floor from the environment, not committed; the step figures of §6 against the build before each step |
