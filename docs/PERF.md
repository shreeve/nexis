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

Hosts: §3.1, §3.4's table and §3.6 on an Apple M1; §3.2, §3.3, §3.5,
§3.6's second column, §3.7, §3.8, §3.11, §3.12, §3.13 and §3.14 on
an Apple M5, as are §3.16 through §3.19; §3.15 on an Intel Core Ultra 9 185H under Linux;
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
| store after the load (allocated) | 144 MB | 46 MB | 3.1 |

The tree at `cc935cc`, where every default commit synced and every
read began its own transaction, measured 3.42 s for the default-commit
transactions, 1.64 s for the default-commit load and 24.6 ms for the
lookups under the same harness (§6 "Levers pulled", §11).

What the rows say:

- nexis is ahead of babashka on every row: 2–4× on loops, calls
  (`fib`), `sort`, transient maps and `frequencies`/`group-by`,
  1.3–1.6× on destructuring, the map build, vector `conj`/`nth`,
  string splitting and the `map`/`filter`/`reduce` pipeline, measured
  with eager sequences. It starts in about 5 ms with a 6 MB resident
  set.
- Sequences are lazy and chunked, as babashka's (`docs/BENCH.md`
  §12). Against the eager build `3f1f9c6`, at `c20942f`, 7
  interleaved rounds (§11):
  - The pipeline's timed phase retires 4.1% more instructions (949 M
    against 912 M) and takes 16% longer (41.8 against 36.2 ms, 171.8 M
    cycles against 148.6 M), with a resident set 2.5% smaller (189
    against 194 MB). Each stage caches the chunks it realizes: 94,000
    chunk steps of two blocks each, and the phase grows the resident
    set by 36 MB where the eager build's vectors grew it by 25 MB; no
    cycle runs in the phase, so every block is fresh memory. Fusing
    the stages into the `reduce` would avoid the chunks, but runs a
    function again when the same seq is also held and walked
    elsewhere, where Clojure caches, so nexis does not.
  - `sort` peaks at the eager build's 154 MB. `frequencies` and
    `group-by` peak at 60 MB against 40 MB: the lazy `map` that
    `frequencies` counts stays reachable from the call's argument
    while the phase's one cycle runs, where the eager build's cycle
    ran before its mapped vector existed (TODO.md #13).
  - Startup retires 48.4 M instructions against 37.6 M (6.7 against
    5.9 ms): the embedded library is 66 KB against 44 KB, at about
    0.5 M instructions a KB.
- Its resident set is below babashka's on every row but `sort`, which
  sorts through about 80 MB of buffers outside the heap (§6).
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
- The store is 3.1× Datalevin's. Half of it is the four history
  indexes and the txlog, which Datalevin does not keep. The per-tree
  table below measures the load under an emdb that split every leaf
  between existing keys in half, before (plain key order) and after a
  two-pass order that refilled them; under emdb's run rule
  (`docs/NEXTOMIC.md` §2.5) plain key order fills its leaves as the
  "after" column does, and the whole store is 144 MB.

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
run. The destructuring loop calls `get`, `nth`, `nthnext` and
`count` as natives; a native call costs a `var:load-var`, the moves
into its block and one `call:call` (its five-argument `+` is four
`math:add`, §3.17).

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

### 3.15 Linux x86_64: nexis against babashka and JVM Clojure, Nextomic against Datalevin and Datomic

The workloads of §3.11 on an Intel Core Ultra 9 185H under Linux, with
two more columns on each side: Clojure 1.12.6 on HotSpot (JDK 21) for
the language, and Datomic Local 1.0.291 and Datomic Pro 1.0.7705
(dev transactor) for the database, by `bench/compare/run.clj --n 10
--max-load 4 --pin 0-11` (`docs/BENCH.md` §12): ten rounds, the
implementations alternating, every process pinned to the six
performance cores' twelve threads, the frequency governor left at
`powersave`. Every workload gave the same answers in every run of
every system. Cells are the median of the time measured inside each
process; a ratio above 1 means nexis is slower. Provenance: §11.

**Language.** Clojure cold is the program's one run in a fresh JVM, as
babashka and nexis run it; Clojure warm is the median of ten runs in
one JVM after twenty discarded ones. The wall columns are the whole
process, start to exit, of the one-shot runs; RSS is its peak.

| Workload | nexis | babashka 1.13 | Clojure cold | Clojure warm | ÷ bb | ÷ cold | ÷ warm | wall: nexis / bb / Clojure | RSS: nexis / bb / Clojure |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| startup (`-e`) | 7.51 ms | 7.22 ms | 327 ms | — | 1.04 | 0.02 | — | (the cells) | 6 / 32 / 109 MB |
| loop/recur, 1M | 40.3 ms | 91.3 ms | 21.8 ms | 13.3 ms | 0.44 | 1.84 | 3.02 | 51 ms / 107 ms / 453 ms | 6 / 85 / 135 MB |
| sort, 1M ints | 143 ms | 331 ms | 201 ms | 147 ms | 0.43 | 0.71 | 0.97 | 203 ms / 443 ms / 662 ms | 137 / 116 / 250 MB |
| `frequencies` and `group-by`, 1M | 103 ms | 242 ms | 166 ms | 106 ms | 0.42 | 0.62 | 0.97 | 166 ms / 359 ms / 631 ms | 57 / 134 / 268 MB |
| fib 30 | 73.7 ms | 159 ms | 14.7 ms | 4.60 ms | 0.46 | 5.02 | 16.0 | 84 ms / 174 ms / 439 ms | 6 / 80 / 113 MB |
| map through transients, 1M | 536 ms | 1.00 s | 452 ms | 358 ms | 0.53 | 1.19 | 1.50 | 554 ms / 1.02 s / 887 ms | 122 / 181 / 314 MB |
| destructuring loop | 363 ms | 429 ms | 112 ms | 37.7 ms | 0.85 | 3.23 | 9.62 | 376 ms / 444 ms / 557 ms | 25 / 86 / 336 MB |
| map build and read, 1M | 1.16 s | 1.43 s | 594 ms | 451 ms | 0.81 | 1.95 | 2.56 | 1.17 s / 1.46 s / 1.06 s | 140 / 195 / 576 MB |
| vector conj and nth, 1M | 131 ms | 121 ms | 67.6 ms | 30.3 ms | 1.08 | 1.93 | 4.31 | 146 ms / 139 ms / 509 ms | 65 / 127 / 260 MB |
| string build and split, 1 MB | 34.2 ms | 29.5 ms | 59.7 ms | 12.6 ms | 1.16 | 0.57 | 2.71 | 46 ms / 44 ms / 496 ms | 30 / 75 / 136 MB |
| map/filter/reduce over 1M maps | 75.9 ms | 46.2 ms | 47.2 ms | 22.6 ms | 1.64 | 1.61 | 3.36 | 288 ms / 560 ms / 553 ms | 195 / 214 / 316 MB |

What the language rows say:

- Warm, HotSpot is faster than nexis on eight of the ten programs:
  1.5× on the transient map, 2.5–4.3× on the map build, string
  splitting, loops, the pipeline and vectors, 9.6× on the
  destructuring loop and 16× on `fib`, where a compiled call is a few
  nanoseconds and a nexis call is an interpreted frame. `sort` and
  `frequencies`/`group-by` are level (0.97): nexis runs them as Zig
  natives, and both sides spend the time in the library.
- Cold, in a fresh JVM, Clojure is still faster inside the timed body
  on seven of ten (1.2–5×), and slower on `sort`,
  `frequencies`/`group-by` and string splitting, whose library code
  the JVM has not compiled yet. Counting the whole process, the JVM's
  start of about 0.33 s puts nexis ahead on every one-shot program
  but the persistent map build (1.17 s against 1.06 s).
- nexis starts in 7.5 ms, level with babashka and 43× faster than
  `clojure -M` (the CLI's launcher included), and its resident set is
  below the JVM's on every row, 1.6–22× smaller.
- Against babashka the picture differs from the Apple host's (§3.11,
  where nexis leads every row): on this host nexis is ahead on seven
  rows (0.42–0.85) and behind on vectors (1.08), string splitting
  (1.16) and the pipeline (1.64), and level at startup. The rows were
  not measured on one machine under both operating systems, so the
  difference is the host and the platform together, not either alone.

**Database.** 100 departments and 100,000 people with five attributes.
The durability of each row (`docs/BENCH.md` §12, traced with `strace`):
Nextomic's default commit syncs nothing and survives a crash of the
process; its durable connection issues two `fdatasync` per commit.
Datalevin's default commit is durable (one `fdatasync` and an
`O_DSYNC` meta write). Datomic Local's one mode is durable (two
`fdatasync`). Datomic Pro's dev transactor acknowledges without a sync
(H2 writes the file in batches), so its commit is closest to
Nextomic's default and weaker: an unwritten batch can be lost with the
transactor.

| Phase | Nextomic | Datalevin 1.1 | Datomic Local | Datomic Pro | ÷ Datalevin | ÷ Local | ÷ Pro |
|---|---:|---:|---:|---:|---:|---:|---:|
| create a store | 695 μs | 81.0 ms | 129 ms | 985 ms | 0.01 | 0.01 | 0.00 |
| load, default commit | 636 ms | 3.64 s (durable) | 9.62 s (durable) | 4.82 s | 0.17 | 0.07 | 0.13 |
| load, every commit durable | 1.45 s | 3.64 s | 9.62 s | — | 0.40 | 0.15 | — |
| index after the load | (in the load) | (in the load) | — | 2.91 s | | | |
| open an existing store | 86 μs | 9.34 ms | 35.7 ms | 705 ms | 0.01 | 0.00 | 0.00 |
| 10k point lookups by a unique attribute | 17.2 ms | 60.3 ms | 269 ms | 249 ms | 0.29 | 0.06 | 0.07 |
| the same, warm (median of nine passes) | 13.0 ms | 47.5 ms | 140 ms | 11.0 ms | 0.27 | 0.09 | 1.18 |
| three-clause join, 20 × 1,000 rows | 24.6 ms | 58.2 ms | 230 ms | 133 ms | 0.42 | 0.11 | 0.18 |
| aggregate query | 34.2 ms | 132 ms | 867 ms | 356 ms | 0.26 | 0.04 | 0.10 |
| pull of 10k entities with a nested ref | 13.8 ms | 135 ms | 300 ms | 81.8 ms | 0.10 | 0.05 | 0.17 |
| the same, warm (median of nine passes) | 12.8 ms | 112 ms | 262 ms | 16.0 ms | 0.11 | 0.05 | 0.80 |
| 1,000 one-datom transactions, default commit | 31.7 ms | 1.98 s (durable) | 5.55 s (durable) | 2.47 s | 0.02 | 0.01 | 0.01 |
| 1,000 one-datom transactions, every commit durable | 2.24 s | 2.02 s | 5.45 s | — | 1.11 | 0.41 | — |
| 1,000 one-datom transactions, no per-commit flush | 33.2 ms | 72.9 ms | — | — | 0.46 | — | — |
| as-of and history query | 3.25 ms | no counterpart | 38.9 ms | 27.7 ms | — | 0.08 | 0.12 |
| store after the load (allocated) | 137 MB | 42 MB | 25 MB | 18 MB | 3.3 | 5.5 | 7.6 |
| peak RSS, query process | 128 MB | 668 MB | 1117 MB | 778 MB + 1127 MB transactor | | | |

Datalevin's and Datomic Local's load and default-commit rows are
already durable, so the durable load row repeats their figure; the
second and third write batches of the Datomic twins run untimed where
no mode matches.

What the database rows say:

- Nextomic is ahead of Datomic Local and Datomic Pro on every phase
  timed cold: 5–25× on lookups, joins, aggregates, pull and the time
  views, and far more on creating and opening a store; its load is
  7.6× faster than Datomic Pro's (before Datomic's indexing) and,
  durable against durable, 6.6× faster than Datomic Local's; small
  default-commit transactions are 78× faster than Datomic Pro's, whose
  transactor round trip (2.5 ms a transaction, no sync) is the cost an
  in-process commit does not pay.
- Warm, Datomic Pro's peer is faster than Nextomic at point lookups
  (11.0 ms against 13.0 ms, 1.18) and close on pull (0.80): once the
  JIT has compiled the peer and its object cache holds the segments,
  a lookup is a lookup in memory. Its cold figures are 23× and 5×
  those, which is what a peer that just started pays. Datomic Local's
  client API stays 10–20× behind even warm.
- Durable against durable, Nextomic's commit (two `fdatasync`,
  2.24 ms) is 11 % slower than Datalevin's (one `fdatasync` and an
  `O_DSYNC` write, 2.02 ms) and 2.4× faster than Datomic Local's
  (5.45 ms). A durable load of 100,000 entities takes 1.45 s, against
  3.64 s and 9.62 s.
- The store is Nextomic's clear loss: 137 MB against Datomic Pro's
  18 MB and Datomic Local's 25 MB, which keep history too (7.6× and
  5.5×), and Datalevin's 42 MB without history (3.3×). Datomic Local's
  `index-eavt` file holds the load in 4.0 MB, about 8 bytes a datom;
  Nextomic's EAVT holds 26 bytes of key and value a datom plus emdb's
  10, and again in its history twin (§3.11's per-tree table).
- Datomic Pro's load returns before it has indexed: the transactor
  folds the log into its indexes in the background, 2.91 s more for
  this load, which Nextomic's 636 ms already includes.
- Memory: Nextomic's query process peaks at 128 MB; Datomic Pro's
  peer at 778 MB beside a 1.1 GB transactor (the distribution's
  `-Xms1g -Xmx1g`), Datomic Local at 1.1 GB, all at the JDK's default
  heap sizing.

### 3.16 Loop shape, Apple M5

What the compiler's loop shape (`docs/COMPILER.md` §5.6, §5.7) saves:
a `recur` computes its arguments in an order that needs no temporary
when one that cannot fail may wait, and repeats the loop's test at its
bottom instead of jumping back to it. Before is the tree at `b0ba2ae`,
after the branch's commit; one ReleaseFast build of each. Provenance:
§11.

Per unit, by `tools/speed/harness.py` over the micro programs of
`.git/revamp/r2/tools/speed/nx` at two sizes (5 M and 10 M iterations;
`fib` 27 and 30, 2,056,916 calls apart), seven interleaved rounds: the
median of the paired differences, the range in brackets.

| Program | Dispatches before → after | Instructions before | after | Cycles before | after |
|---|---|---:|---:|---:|---:|
| `count`, `(recur (inc i))` | 3 → 2 | 210.0 [209.5–210.2] | 195.0 [194.3–195.3] | 22.4 [19.2–28.9] | 20.1 [19.0–27.9] |
| `acc`, `(recur (inc i) (+ acc i))` | 5 → 3 | 353.1 [352.8–353.3] | 281.0 [280.7–281.3] | 40.7 [39.1–55.5] | 32.5 [21.3–46.8] |
| `lc`, `(recur (inc i) 7)` | 4 → 3 | 255.0 [254.9–255.3] | 240.0 [239.7–240.2] | 31.2 [24.1–41.4] | 27.7 [21.2–31.5] |
| `gcall`, `(recur (inc i) (f 7))` | | 496.2 [495.9–496.4] | 481.1 [480.3–481.2] | 66.7 [55.8–82.1] | 59.5 [50.7–66.1] |
| `fib`, per call (no loop) | | 488.6 [488.4–488.8] | 488.6 [488.4–489.3] | 76.1 [70.8–93.6] | 80.0 [75.7–93.5] |

`fib`'s bytecode is the same in both builds; its cycles moved either
way pair by pair (after worse in four of seven), as the handlers'
addresses moved.

The `bench/compare` programs, whole process under `/usr/bin/time -l`
(five rounds) and the phase each times itself (nine rounds),
interleaved:

| Workload | Instructions before | after | Phase before | after |
|---|---:|---:|---:|---:|
| loop/recur, 1M | 588.4 M | 516.2 M (−12.3 %) | 14.2 ms [13.7–15.5] | 12.2 ms [11.6–14.1], faster in 9 of 9 |
| destructuring loop | 6,165 M | 6,044 M (−2.0 %) | 235.3 ms [231.4–239.5] | 227.8 ms [225.1–232.0], faster in 9 of 9 |
| fib 30 | 1,365 M | 1,365 M | 49.2 ms | 49.7 ms, slower in 5 of 9 |
| map/filter/reduce over 1M maps | 3,106 M | 3,107 M | 41.1 ms | 42.9 ms, slower in 7 of 9 |

Every other language workload is within 0.05 % in instructions;
startup (`-e nil`, 21 rounds) 48.39 M → 48.44 M. The pipeline's
timed phase runs no loop the change touches (its bytecode lists the
same); its cycles follow the binary's layout. `nexis-bench --filter
vm,compiler`, five invocations each, alternating, medians of the five:
`vm_loop_10k` 57.9 → 52.9 μs, `vm_global_call_10k` 147.0 → 144.0 μs,
`vm_keyword_get_10k` and `eval_simple_loop` within the spread.

### 3.17 Arithmetic past two arguments, Apple M5

`+`, `*` and `-` past two arguments lower to a left fold of `math`
instructions over the arguments' values (`docs/COMPILER.md` §4.3)
instead of a call of the native through its Var. Before is the
tree after §3.16's change, after the branch's commit; one ReleaseFast
build of each. Provenance: §11.

| Measure | Before | After |
|---|---:|---:|
| `(recur (inc i) (+ acc i 1 2))`, instructions an iteration (7 rounds, 5 M/10 M) | 745.1 [745.0–745.2] | 455.1 [455.0–455.1] |
| the same, cycles an iteration | 98.6 [95.4–100.8] | 51.3 [46.3–57.4] |
| destructuring loop, whole process (5 rounds) | 6,044 M instructions | 5,755 M (−4.8 %) |
| destructuring loop, its timed phase (9 interleaved rounds) | 246.9 ms [244.0–252.7] | 229.9 ms [226.2–236.4], faster in 9 of 9 |
| `count`, `fib` per call, `gcall` (instructions) | 194.9, 488.5, 481.0 | 195.0, 488.6, 481.0 |

The destructuring loop's `(+ a b x y (count more))` was a
`var:load-var`, four moves and a five-argument call; it is four
`math:add`. Every other language workload is within 0.3 % in
instructions (`sort` 2,790 → 2,783 M), startup 48.49 → 48.53 M. In
`bench/compare/run.clj`'s four alternating runs and a rerun of five
rows, the destructuring phase was 237.6, 236.6, 222.7, 218.0 ms
before and 228.9, 226.0, 206.9, 210.9 ms after; the other rows moved
with babashka's in the same rounds (load 10–14).

### 3.18 The stdlib image, Apple M5

Startup before and after booting the library from its precompiled
image instead of its sources (`docs/STDLIB.md` §1): `bin/nexis` built
at `b0ba2ae` (before) and at `587f87f` (after), 21 interleaved rounds
of each command under `/usr/bin/time -l`; medians, the instruction
range in brackets. Provenance: §11.

| Command | Instructions | Cycles | Wall | Resident set |
|---|---:|---:|---:|---:|
| `-e nil` before | 48.54 M [48.40–56.23] | 14.24 M | 5.91 ms | 5.96 MB |
| `-e nil` after | 21.44 M [21.34–25.24] | 6.57 M | 4.07 ms | 3.62 MB |
| `-e '(+ 1 2)'` before | 48.50 M [48.43–48.92] | 14.11 M | 5.66 ms | 6.00 MB |
| `-e '(+ 1 2)'` after | 21.48 M [21.39–21.81] | 6.49 M | 3.85 ms | 3.74 MB |

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
- Verifying every routine of the image as it loads (`docs/VM.md` §5),
  measured on the tree with fast dispatch: `-e nil` 21.85 M
  instructions [21.52–23.17] without, 22.20 M [21.96–22.96] with, 21
  interleaved rounds at a load of 8.8–9.2, cycles and wall time inside
  the spread. 0.35 M, 1.6% of a start, for a fact the build's
  generator already proved of the same bytes: release builds skip it
  (`docs/STDLIB.md` §1).

### 3.19 Fast dispatch, Apple M5

The phase as a whole, the base `b0ba2ae` against `93862af`, five
interleaved rounds at a load of 4–6 (instructions / cycles a unit,
medians):

| Program | Base | Fast dispatch |
|---|---:|---:|
| `count` | 210.0 / 22.5 | 117.0 / 14.4 |
| `acc` | 352.9 / 37.5 | 188.0 / 25.8 |
| `fib`, per call | 488.6 / 72.6 | 297.5 / 50.4 |
| `gcall` | 496.1 / 57.7 | 297.0 / 34.6 |
| `lc` | 255.0 / 27.4 | 139.0 / 21.9 |
| `lv` | 260.0 / 27.8 | 145.0 / 19.0 |
| `mv` | 267.0 / 28.7 | 143.0 / 19.5 |
| `kw` | 477.2 / 57.5 | 320.2 / 41.5 |
| `leaf` | 625.2 / 70.5 | 400.0 / 51.8 |
| `getnl` | 792.1 / 105.3 | 516.1 / 69.5 |
| `cbsum` less `cbbase`, per element | 86.4 / 22.0 | 85.1 / 21.1 |
| `cbred` less `cbbase` | 297.6 / 49.7 | 229.5 / 45.8 |
| `cb` less `cbbase` | 274.3 / 48.1 | 250.9 / 46.9 |
| `lazy` less `cbbase` | 364.9 / 77.3 | 334.8 / 69.2 |
| `lazy3`, 201 MB peak both | 442.6 / 108.0 | 433.5 / 107.4 |

Startup (`-e nil`) retires 48.3 → 48.9 M instructions: verifying the
boot's top-level forms costs 0.6 M, its wall time inside the run's
spread.

The steps one by one follow.

The cost of one iteration or call of the micro programs
(`bench/micro/`, `docs/BENCH.md` §13) in machine instructions retired
and cycles, before and after each step of the fast dispatch
(`docs/VM.md` §8): the median of five interleaved rounds, each
program at two sizes, with the range of the rounds in brackets.
Instructions are reproducible to a tenth; cycles moved with the load
(12 to 15 on a shared host). Provenance: §11.

| Program | Before: one table | Frameless fast handlers | `pc` in a register |
|---|---:|---:|---:|
| `count` (3 dispatches) | 209.9 [208.6–210.1] / 23.6 cycles [19.3–32.1] | 175.0 [174.3–175.1] / 18.9 [16.9–26.5] | 158.9 [158.9–159.0] / 17.4 [16.5–18.1] |
| `acc` (5) | 353.0 [353.0–353.1] / 34.8 [31.1–41.1] | 282.1 [281.9–282.3] / 37.3 [34.2–40.3] | 256.0 [255.8–256.1] / 28.4 [27.4–28.6] |
| `fib`, per call | 488.5 [488.1–488.8] / 76.8 [73.0–85.4] | 414.5 [414.3–414.9] / 59.6 [52.2–61.7] | 378.9 [378.9–379.0] / 51.0 [49.3–51.9] |
| `gcall` | 496.1 [495.9–496.2] / 57.5 [43.9–61.5] | 426.0 [426.0–426.1] / 47.2 [46.0–56.1] | 380.0 [379.9–380.0] / 41.6 [38.4–42.2] |
| `lc` (`count` + `mov:load-const`) | 255.0 / 26.4 | 207.0 / 27.2 | 189.0 / 19.1 |
| `mv` (+ `mov:move`) | 267.0 / 30.4 | 215.0 / 24.9 | 195.0 / 20.7 |
| `lv` (+ `var:load-var`) | 260.0 / 29.1 | 218.0 / 27.5 | 195.0 / 21.0 |
| `kw` (+ a keyword lookup) | 477.1 / 63.4 | 408.1 / 46.5 | 394.0 / 42.4 |
| `leaf` (+ a leaf native call) | 625.2 / 74.6 | 524.1 / 69.1 | 494.0 / 57.3 |
| `getnl` (+ a native call through its buffer) | 730.0 / 87.7 | 668.2 / 85.8 | 634.1 / 77.3 |

Each column is measured against the one before it in its own run of
five rounds (the middle column twice; the table keeps its first run).
The fast handlers alone moved cycles little: each dispatch stored
`frame.pc` and the next loaded it, a chain carried from one
instruction to the next. With `pc` in a register the chain is gone.

`acc`'s cycles fell only with `pc` in a register: before, both the
chain through `frame.pc` and its loop's chain through the slots (`i`
written by one handler and read by the next) bound it.

Verified once per routine (`docs/VM.md` §5, §8), the fetch and the
fast handlers check no bound, and the fast handlers read a slot's
value a word at a time, as it was stored. Seven interleaved rounds
against the hot-section build, load 7–8:

| Program | Before | Verified |
|---|---:|---:|
| `count` | 158.0 [156.5–158.2] / 16.8 [15.1–20.2] | 117.0 [116.4–117.5] / 12.6 [10.3–17.1] |
| `acc` | 254.9 / 27.0 | 188.1 / 26.1 |
| `fib`, per call | 377.1 / 50.7 | 302.5 / 50.6 |
| `gcall` | 379.1 / 41.3 | 302.1 / 36.7 |
| `lc` | 188.1 / 20.9 | 139.1 / 21.6 |
| `mv` | 194.1 / 21.2 | 142.9 / 17.7 |
| `lv` | 194.1 / 21.0 | 145.0 / 20.2 |
| `kw` | 393.2 / 44.9 | 320.1 / 41.8 |
| `leaf` | 493.2 / 62.9 | 401.0 / 52.3 |
| `getnl` | 633.1 / 74.5 | 536.3 / 81.5 |

Without the word reads the same build retired the same instructions
and lost cycles where a loop carries a value through its slots (`acc`
28.6 → 39.7, `lv` 23.9 → 29.6 cycles, 25 rounds): a handler reading a slot's
kind byte, or both words in one 16-byte load, right after the handler
before it stored the value as two words, waits for the store to reach
the cache; the slower handlers before had left it time to. `lc` and
`lv` stay bimodal across runs (`lc` 9.6–38.7 cycles in fifteen
rounds against 17.2–21.3 before, medians 24.0 and 19.6), as the
address of the stack against the constant pool or the Var changes
from run to run: the next measurement is where the slots sit.

The fast `call:return` filling the cell of a frame a native pushed
(a `Callback`, `callValue`) instead of handing it to the general
handler, five rounds: a closure callback's element `cbred` 264.1 →
229.2 instructions (42.4 → 45.2 cycles, ranges overlapping), `cb`
285.7 → 250.6 (49.9 → 42.8), `lazy` 369.7 → 334.7 (76.0 → 70.3);
`fib` 302.5 → 297.5 a call, the call's own return no longer testing
whether the loop's frame has returned.

**The pipeline row and the runtime's place.** Against the base, the
whole tree retired fewer instructions on every `bench/compare`
language row, yet the pipeline's timed phase ran 45 → 56 ms, from the
commit that dropped the frame pointer on. The phase's own instructions
fell (949 → 816 M) and its cycles rose (157 → 209 M); each stage alone
ran faster than the base, only the four together slower; 256 or
1,024 bytes more of native stack under a callback, or the frame
pointer kept, put it back at 44 ms. The `Runtime`, and the VM in it,
lived on the runtime thread's stack, at a fixed distance from the
frames of the natives a callback runs under, so a native's store a
multiple of 4 KiB from a VM field made the next handler's load of the
field wait; which store did depended on the frames' sizes. With the
`Runtime` on the heap (`src/cli.zig`) the phase runs 37.7 ms. The
language rows then, base `b0ba2ae` against this tree, one run each of
whole-process instructions and cycles (millions):

| Row | Instructions | Cycles |
|---|---:|---:|
| `loop` | 588 → 346 | 93 → 53 |
| `fib` | 1,365 → 851 | 223 → 181 |
| `destructure` | 6,166 → 4,773 | 1,053 → 846 |
| `pipeline` | 3,087 → 2,698 | 647 → 610 |
| `freq-group` | 1,945 → 1,710 | 461 → 415 |
| `map-build-read` | 4,341 → 3,924 | 3,317 → 3,261 |
| `map-transient` | 2,727 → 2,330 | 1,820 → 1,674 |
| `sort` | 2,783 → 2,678 | 561 → 504 |
| `string-split` | 407 → 378 | 72 → 77 |
| `vector-conj-nth` | 1,398 → 1,225 | 240 → 206 |

Peak RSS is unchanged on every row.

The fast handlers in a section of their own, each on a cache line, in
seven rounds at a load of 14: cycles a unit `count` 18.2 → 17.6, `acc`
29.9 → 27.7, `fib` 50.6 → 49.9, `gcall` 42.1 → 40.1, `mv` 21.9 → 20.1,
`lv` 22.6 → 21.0, the instructions unchanged; every median lower,
every range overlapping the other's.

### 3.20 The speed phase, Apple M5

The three changes of §3.16–§3.19 together: main at `70db20b` (before)
against the speed branch at `35a85bd` (after), one ReleaseFast
`bin/nexis` of each. Provenance: §11.

The micro kit (`bench/micro/`, `docs/BENCH.md` §13), seven interleaved
rounds at a load of 5.1–6.6: instructions and cycles an iteration, a
call or an element, medians with the range of the rounds.

| Program | Instructions before | after | Δ | Cycles before | after |
|---|---:|---:|---:|---:|---:|
| `count` | 209.9 [209.9–210.2] | 106.9 [106.9–107.0] | −49% | 23.4 [17.8–27.8] | 13.3 [12.1–17.3] |
| `acc` | 353.0 [352.9–353.3] | 152.0 [152.0–152.0] | −57% | 38.0 [33.8–42.9] | 27.7 [25.2–29.7] |
| `fib`, per call | 488.5 [488.3–489.0] | 297.4 [297.3–297.5] | −39% | 71.6 [65.7–73.4] | 50.7 [47.9–51.8] |
| `gcall` | 495.9 [495.8–496.3] | 287.0 [287.0–287.4] | −42% | 58.6 [50.6–60.2] | 33.1 [29.1–35.4] |
| `lc` | 255.0 | 129.0 | −49% | 27.6 [25.6–32.1] | 21.9 [17.8–26.5] |
| `lv` | 260.0 | 135.0 | −48% | 28.7 [27.9–31.4] | 20.5 [17.0–23.6] |
| `mv` | 267.0 | 133.0 | −50% | 28.6 [28.4–32.1] | 20.5 [14.0–25.7] |
| `kw` | 477.0 | 310.0 | −35% | 58.6 [56.1–62.1] | 36.6 [35.9–39.5] |
| `leaf` | 625.0 | 364.0 | −42% | 68.7 [68.3–71.7] | 46.8 [42.0–53.5] |
| `getnl` | 792.0 | 506.0 | −36% | 109.8 [96.9–128.4] | 66.6 [63.8–72.4] |
| `cbsum` less `cbbase`, per element | 86.5 | 85.2 | −1.5% | 21.1 | 21.4 |
| `cbred` less `cbbase` | 297.3 | 229.5 | −23% | 48.9 [42.8–59.0] | 45.3 [44.4–50.4] |
| `cb` less `cbbase` | 274.2 | 250.9 | −8.5% | 48.8 | 44.6 |
| `lazy` less `cbbase` | 364.3 | 335.1 | −8.0% | 76.8 | 70.5 |
| `lazy3`, peak RSS 201 → 199 MB | 442.4 | 433.4 | −2.0% | 111.4 | 109.1 |

The ranges of the instructions are a tenth wide where not shown.
Cycles fell on every program but `cbsum`, whose callback is a leaf
native none of these changes touched.

Startup, 21 interleaved rounds at a load of 5.9 (medians, the
instruction range in brackets):

| Command | Instructions | Cycles | Wall | Resident set |
|---|---:|---:|---:|---:|
| `-e nil` before | 48.35 M [48.20–48.79] | 14.13 M | 5.74 ms | 6.0 MB |
| `-e nil` after | 21.71 M [21.53–22.01] | 6.54 M | 4.04 ms | 3.7 MB |
| `-e '(+ 1 2)'` before | 48.42 M [48.23–48.50] | 14.22 M | 5.87 ms | 6.0 MB |
| `-e '(+ 1 2)'` after | 21.75 M [21.66–21.88] | 6.65 M | 3.98 ms | 3.8 MB |

The `bench/compare` language rows: each program's whole process under
`/usr/bin/time -l` (five interleaved rounds, medians; startup is in
it, about 27 M instructions fewer after), and the phase each program
times itself, the median of `run.clj`'s ten rounds in each of four
runs, after, before, after, before (load 5.4–6.1), with the resident
set:

| Row | Instructions | Cycles | Phase before (two runs) | after (two runs) | RSS |
|---|---:|---:|---:|---:|---:|
| startup (`-e`) | | | 6.09, 6.10 ms | 4.11, 4.21 ms | 6 → 4 MB |
| loop/recur, 1M | 588 → 284 M (−52%) | 72.8 → 40.7 M | 14.8, 15.1 ms | 8.1, 8.5 ms | 6 → 4 MB |
| fib 30 | 1,364 → 824 M (−40%) | 213 → 143 M | 50.0, 50.5 ms | 35.1, 33.2 ms | 6 → 4 MB |
| destructuring loop | 6,163 → 4,334 M (−30%) | 982 → 700 M | 253, 249 ms | 179, 179 ms | 25 → 22 MB |
| map/filter/reduce over 1M maps | 3,087 → 2,670 M (−13%) | 573 → 509 M | 43.0, 43.2 ms | 39.0, 39.6 ms | 189 → 188 MB |
| vector conj and nth, 1M | 1,398 → 1,196 M (−14%) | 215 → 185 M | 50.2, 50.1 ms | 45.3, 46.0 ms | 36 → 34 MB |
| string build and split, 1 MB | 407 → 347 M (−15%) | 71.0 → 59.2 M | 13.5, 13.5 ms | 12.7, 12.7 ms | 34 → 31 MB |
| `frequencies` and `group-by`, 1M | 1,945 → 1,682 M (−13%) | 416 → 392 M | 83.4, 85.2 ms | 81.0, 79.1 ms | 60 → 59 MB |
| map through transients, 1M | 2,724 → 2,260 M (−17%) | 1,263 → 1,187 M | 333, 301 ms | 321, 313 ms | 87 → 85 MB |
| map build and read, 1M | 4,333 → 3,850 M (−11%) | 2,341 → 2,400 M | 587, 641 ms | 596, 624 ms | 98 → 96 MB |
| sort, 1M ints | 2,781 → 2,649 M (−4.7%) | 466 → 444 M | 96.9, 95.2 ms | 98.1, 97.1 ms | 154 → 153 MB |

Every answer was equal in every run. Every row retires fewer
instructions and holds no more memory. The rows whose time is the
interpreter's (loop, fib, destructuring, the pipeline, vector
`conj`/`nth`, string splitting, startup) ran 6–44% faster in every
run, and `frequencies`/`group-by` 5%. The rows whose time is the
natives' moved within the spread of their runs: the transient map,
the map build (more cycles in its whole process, 2,341 → 2,400 M)
and `sort` (1.6% slower in its phase, 4.7% fewer cycles in its whole
process).

§3.11's table predates these changes: its startup, loop, fib,
destructuring, pipeline, vector, string and `frequencies` rows
overstate nexis's times by about the margins above, and its other
rows stand.

### 3.21 Calls and callbacks, Apple M5

What one iteration, call or element of the micro programs
(`bench/micro/`, `docs/BENCH.md` §13) costs in machine instructions
retired and cycles, before and after each change to the call path
(`docs/VM.md` §6–§7): medians of five interleaved rounds, the range of
the rounds in brackets where it is wider than a tenth. Provenance:
§11.

**A leaner call and return.** The frame drops its `slot_count` (the
routine's) and `return_pc` (the caller's own `pc` is its return
point) and is 64 bytes, one cache line; a call no longer counts the
closure's cells against its routine's upvalues (every closure is built
with one per upvalue, §6) or, in a release build, moves the stack and
frame high-water marks; the fast `call:call` tests for a closure
first and fetches the callee's first instruction through the routine
in hand. Load 7.0 → 6.7:

| Program | Instructions before | after | Cycles before | after |
|---|---:|---:|---:|---:|
| `fib`, per call | 297.5 | 280.5 (−5.7%) | 51.9 [49.8–52.8] | 46.8 [46.4–47.1] |
| `gcall` | 287.0 | 270.0 (−5.9%) | 34.1 [33.6–34.5] | 32.3 [31.7–32.4] |
| `count` | 107.0 | 106.9 | 12.4 | 12.0 |
| `cbred` less `cbbase` | 229.2 | 226.3 | 45.8 | 43.8 |
| `cb` less `cbbase` | 250.5 | 241.8 | 44.5 | 44.6 |
| `lazy` less `cbbase` | 334.7 | 330.4 | 70.0 | 68.4 |

Every other program of the kit retired the same instructions within
one. The `bench/compare` programs, whole process, five interleaved
rounds (load 6.5 → 6.4): `fib` 823.6 → 777.8 M instructions and its
phase 32.3 → 29.4 ms, `freq-group` 1,682 → 1,654 M, `pipeline` 2,669 →
2,655 M, `destructure` 4,334 → 4,309 M, the rest within 0.4%; the
resident set unchanged.

The fast handlers trust the slots verification proved (§8). Asserted
as `std.debug.assert(index < frame.routine.slot_count)`, which a
release build assumes, the bound read through the frame's routine
moved the routine's load to the top of every fast handler, and the
counting loop ran 20–24 cycles an iteration against 12–14 with the
same 107 instructions; twelve runs of each build, every one slower.
Debug and safe builds assert it; release builds do not assume it
(`VM.proved`).

**A callback's call entered at its callee.** A `Callback`'s call of a
closure makes the run loop's first pass itself: it sets the loop's
depth and nesting, takes the safe point of the loop's entry and calls
the callee's first handler directly, so neither `loop` nor its tests
run per element; only an error goes on to the loop (`docs/VM.md`
§6). With it, the return of a frame a host pushed ends the chain
without testing whether the loop's frame has returned, the result
cell is read without a copy through the stack, and a safe point reads
the heap's counter against its limit before the four flags that can
switch collection off (`VM.gcDue`). `group-by` calls its function
through a `Callback`. Load 5.1 → 5.1:

| Program | Instructions before | after | Cycles before | after |
|---|---:|---:|---:|---:|
| `cbred` less `cbbase`, per element | 226.3 | 206.2 (−8.9%) | 43.9 [42.4–49.7] | 44.1 [43.0–45.8] |
| `cb` less `cbbase` | 241.8 | 219.7 (−9.1%) | 44.6 | 41.5 |
| `lazy` less `cbbase` | 330.3 | 304.4 (−7.8%) | 68.8 | 63.6 |
| `cbsum` less `cbbase` | 85.2 | 78.2 (−8.2%) | 21.1 | 21.6 |
| `lazy3` | 433.2 | 401.6 (−7.3%) | 108.1 | 99.6 |
| `leaf` | 364.0 | 358.0 | 48.1 | 46.7 |
| `getnl` | 505.0 | 499.0 | 67.0 | 67.1 |
| `fib`, `gcall`, `count` | 280.5, 270.0, 106.9 | 280.4, 270.0, 106.9 | 46.7, 34.2, 13.8 | 46.6, 33.8, 13.1 |

The `bench/compare` programs, whole process, five interleaved rounds
(load 5.0 → 5.0): `freq-group` 1,654 → 1,536 M instructions (−7.1%)
and its phase 76.6 → 65.3 ms, `pipeline` 2,655 → 2,542 M (−4.3%),
`vector-conj-nth` 1,194 → 1,128 M, `map-transient` 2,252 → 2,136 M,
`map-build-read` 3,842 → 3,726 M, `destructure` 4,310 → 4,256 M,
`sort` 2,640 → 2,616 M, `string-split` 346 → 339 M; `loop` and `fib`
unchanged; the resident set unchanged.
The database rows (`run.clj --only db`, after, before, after, before,
load 4.2 → 5.5) moved within their spread: `aggregate` 17.8, 19.6 →
17.9, 18.0 ms, `lookup-10k` 10.6, 10.8 → 10.1, 10.1 ms.

**The deep-data check inline.** Every call of a native that is not a
leaf compares the spoil counter before and after (`VM.checkDeepData`,
§13.1 of `docs/VM.md`). Out of line, the check saved six register
pairs before reading the counter; inline, the common case is the read
and a compare, and the raise is a call of its own. Load 5.2 → 5.3:
`getnl` 500.0 → 476.0 instructions an iteration (64.4 → 61.9 cycles),
every other program of the kit within a tenth; the `bench/compare`
programs `destructure` 4,260 → 4,099 M (−3.8%), `map-transient`
2,138 → 2,071 M, `map-build-read` 3,727 → 3,679 M, `vector-conj-nth`
1,127 → 1,103 M, `string-split` 339 → 331 M, `pipeline` 2,542 →
2,522 M, the rest unchanged; the phases within their ranges.

**A native's call block cleared after the call** (a memory lever,
`docs/VM.md` §6). Load 5.5 → 5.5 for the kit, 5.5 → 6.0 for the
programs, whose cycles and phases a busy host spread too wide to
read:

| Program | Instructions before | after | Peak resident set |
|---|---:|---:|---:|
| `lazy3` 3 M, whole process | 1,218 M | 1,095 M (−10%) | 199.2 → 61.2 MB |
| `lazy3`, per element | 401.4 | 366.4 | |
| `getnl` | 476.0 | 485.9 (+2.1%) | |
| `destructure` | 4,099.6 M | 4,141.6 M (+1.0%) | 22.3 MB both |
| `map-transient` | 2,070.6 M | 2,095.1 M (+1.2%) | 84.8 MB both |
| `map-build-read` | 3,679.8 M | 3,702.9 M (+0.6%) | 96.3 MB both |

Every other program of the kit and of `bench/compare` retired the same
instructions within 0.4%, and every other resident set is unchanged:
in `freq-group`, `pipeline` and `sort` no seq a native was given is
walked after its call. The clearing costs about ten instructions a
call of a native that is not a leaf, against the 24 the inline
deep-data check above saved. Less marking pays for it in `lazy3`,
whose inner seqs, 138 MB of them, are garbage once the call that
took each has returned.

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
- **Store size** (§3.11, 3.1× Datalevin; §3.15, 7.6× Datomic Pro,
  which keeps history in about 8 bytes a datom an index). A history index that holds
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
  sites**: the fast handlers test their operands' kinds at run time
  (`docs/VM.md` §8); an opcode per kind pair drops the tests at the
  cost of instruction rows.
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
- **Frameless fast handlers on x86-64**: the comparisons, the
  arithmetic and `call:call` save one to six callee-saved registers there
  (`zig build codegen`), where System V leaves nine scratch registers
  and the handler's arguments take four. The `preserve_none` calling
  convention (`x86_64_preserve_none`, every register scratch) for
  every handler would remove the saves; it needs an x86-64 host to
  run the gate and to measure.
- **A compare-and-branch instruction**: an `if` on `(< i n)` is
  `cmp:lt` into a slot and `jump:if-false` on it, which the dispatch
  runs as one (`docs/VM.md` §8, §3.12). One encoded instruction would
  also drop the slot write and a fetch, but two operands and a jump
  target do not fit it (VM.md §3), so it needs the encoding's
  amendment.

**Levers pulled.**

- *The stdlib image* (`docs/STDLIB.md` §1): the build boots the
  embedded sources once and every binary loads what they left;
  startup 48.5 → 21.4 M instructions, 5.9 → 4.1 ms, 6.0 → 3.6 MB
  (§3.18).

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
- *Frameless fast handlers* (`docs/VM.md` §8, §3.19): the hot
  opcodes' fast handlers over the general table, reaching the general
  handler through the table indexed at run time, and release builds
  without a frame pointer. A first attempt tail-called the general
  handler through a constant function pointer; the compiler inlined
  it back and kept the stack frame the fast path was meant to drop
  (the pipeline's phase 876 → 854 M instructions, inside the spread).
  Through the table: the counting loop 210 → 175 instructions an
  iteration, a `fib` call 488.5 → 414.5; with `pc` passed from handler
  to handler in a register, 159 and 379, and the counting loop's
  cycles 23.6 → 17.4; with routines verified once and slots read by
  words, 117 and 302.5, 12.6 cycles.
- *A built sequence walked as its vector* (`docs/LIST.md` §3,
  `viewCursor`): the pipeline's phase 1,327 → 1,253 M instructions on
  the tree before §3.13's changes, which stepped a list inline in the
  place.

- *The loop's shape* (§3.16, `docs/COMPILER.md` §5.6, §5.7): a
  `recur` orders its arguments so none waits in a temporary, moving
  one that cannot fail after one that reads its binding, and repeats
  the loop's test at its bottom. The counting loop 3 → 2 dispatches
  (210 → 195 instructions), `(recur (inc i) (+ acc i))` 5 → 3
  (353 → 281); §3.11's loop row 588 → 516 M instructions, the
  destructuring loop 6,165 → 6,044 M.

- *`+`, `*` and `-` inlined at any arity* (§3.17, `docs/COMPILER.md`
  §4.3): every argument computed, then a left fold of `math`
  instructions, as the native computes it. The destructuring loop
  6,044 → 5,755 M instructions and 246.9 → 229.9 ms.

**Dead ends, measured and reverted** (hosts of §3.7 and §3.8):

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
| §3.11 language and database rows | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224, Datalevin 1.1.0; emdb `ee61850`; shared with concurrent sessions (load average 3.8 at the start and the end) | 2026-09-28 00:52 MDT: `bb bench/compare/run.clj --n 10 --max-load 5` at `7b50fa4`; ten rounds after a discarded warm-up (startup thirty), the implementations alternating, each workload started below a load average of 5 and repeated if the load rose past it; every answer equal; raw results kept with the run (`results.json`) |
| §3.15 | Intel Core Ultra 9 185H (6 performance cores with 2 threads each, 8 efficiency and 2 low-power cores; 22 logical CPUs), 30 GiB, Ubuntu 26.04.1 LTS, Linux 7.0.0-34-generic, ext4 on NVMe, cpufreq governor `powersave` (left as the host has it); every process pinned with `taskset -c 0-11`, the performance cores' threads (4.8–5.1 GHz maximum); nexis `95791b0` and emdb `e4fd537` (a source snapshot, not a checkout), Zig 0.16.0, ReleaseFast; babashka v1.13.224; Datalevin 1.1.0; Temurin OpenJDK 21.0.12.1, Clojure CLI 1.12.6.1673, Clojure 1.12.6, the JDK's default flags with `-XX:-UsePerfData` and `-Djava.io.tmpdir` (the CLI adds `-XX:-OmitStackTraceInFastThrow`); Datomic Local 1.0.291; Datomic Pro 1.0.7705, dev transactor with its distribution's JVM options and the dev template's memory settings; the owner's workstation in use (1-minute load average 1.2–3.2 during the run, 2.1 at the start, 2.5 at the end) | 2026-09-28 01:51–02:17 MDT: `bb bench/compare/run.clj --n 10 --max-load 4 --pin 0-11 --no-build --impls nexis,bb,clojure,datalevin,datomic-local,datomic-pro --datomic-pro DIR --nexis-commit 95791b0 --emdb-commit e4fd537` with the ws-compare-linux `bench/`; ten rounds after a discarded warm-up (startup thirty), the implementations alternating, the Clojure warm column the median of ten calls after twenty in one JVM; every workload on its first attempt, below the load limit of 4; every answer equal; raw results kept with the run (`results.json`, `src/`). The durability of each system from `strace -f` of 200 one-datom transactions on the same host |
| §6 "Levers pulled", the `cc935cc` figures of §3.11 | the same host, shared with concurrent builds (1-minute load average 5–15) | 2026-09-26: `bb bench/compare/run.clj --only db --n 10 --max-load 6 --no-build` over ReleaseFast binaries of the ws-durability branch (after) and of `cc935cc` (before), run one after the other; each run's third attempt, the first two having seen the load pass 6; ten rounds after a warm-up. The `bin/nexis` read figures: a probe program timing 10,000 of each operation over 10,000 entities with `nano-time`, three runs of each binary, alternating. `db_put_commit_scalar`: `zig build bench -Doptimize=ReleaseFast -- --filter db-integrated,nextomic`, three invocations at the branch head and two at `cc935cc`, alternating, the best median; §3.6's durable M5 figure is the `cc935cc` run's, and the branch head measured 7.2–8.9 ms under `NEXIS_DURABILITY=durable` at load 7 |
| §3.11 sequences and strings | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds | revamp, 2026-09-26, ws-strseq: `bb bench/compare/run.clj --n 10 --workloads string-split,pipeline,destructure`, before at `cc935cc` (`--max-load 12`, load 27 falling to 8), after at `c0d6043` (`--max-load 6`); the instruction counts from `/usr/bin/time -l bin/nexis run` of each workload's program, five or seven runs per build, minus a run of its setup alone |
| §3.11 lazy sequences against the eager build | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; shared with concurrent builds (load average 3.4–5.6) | 2026-10-06, perf-regress: the `bench/compare` bodies of `pipeline`, `sort` and `freq-group` after `prelude.nx`, and `-e nil`, run by `bin/nexis` built with `zig build install -Doptimize=fast` at `3f1f9c6`, `240c2b4` and `c20942f`, 7 interleaved rounds under `/usr/bin/time -l`; a phase's instructions and cycles are its program's minus the same program without the timed part, its time the program's own `nano-time` figure, the resident set the process's maximum; medians |
| §3.11 per-tree table | Apple M5, macOS 27.0, Zig 0.16.0, ReleaseFast, shared with concurrent builds | 2026-09-26: `nexis-load.nx STORE nosync` and `durable` built by `cc935cc` (before) and the ws-storesize head (after), read by a read-only program over emdb's `treeStat` and a cursor walk of each tree; fill counts 10 bytes of pointer and node header per entry over 16,352 usable bytes a leaf. The out-of-line rows: 20,000 `:doc/body` strings of 282 bytes, 1,000 per transaction with `:sync :none`, then each replaced once |
| §3.12 | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds (load average 3–9) | revamp, 2026-09-26, ws-dispatch: `nexis-bench` and `bin/nexis` built at `968aa77` (before) and at `5f724d7` (after); `nexis-bench --filter vm,compiler` five times per build, alternating; `bb bench/compare/run.clj --n 10 --max-load 6 --no-build --workloads fib,loop,destructure,sort,map-build-read,pipeline` four times, the builds alternating, each run's report naming the tree's head since the binary was swapped in |
| §3.16 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; babashka v1.13.224; emdb `847c5d8`; shared with concurrent builds | 2026-10-06, speed-c: `bin/nexis` and `nexis-bench` built with `-Doptimize=fast` at `b0ba2ae` (before) and at the branch's loop-shape commit (after). Micro programs: `python3 harness.py OUT 7 A,B -- count.nx:5000000 count.nx:10000000 acc.nx:… fib.nx:27 fib.nx:30 gcall.nx:… lc.nx:…` under `tools/heavy` (one core), load 9.5 at the start and 9.4 at the end; the `bench/compare` programs as `run.clj` writes them, whole process by `cmds.py` five rounds (load 8.9 → 8.6) and the self-timed phase nine interleaved rounds (load 4.4 → 4.3); `bb bench/compare/run.clj --n 10 --only lang --impls nexis,bb --no-build --max-load 16` four times, after, before, after, before (load 10.3 → 9.6), every answer equal; `nexis-bench --filter vm,compiler` five times per build, alternating (load 5.0 → 4.9). Raw output: `.git/revamp/r2/bench/spd-4/` |
| §3.17 | as §3.16 | 2026-10-06, speed-c: `bin/nexis` built with `-Doptimize=fast` at the loop-shape commit (before) and at the branch's arithmetic commit (after). `harness.py OUT 7 A,B -- add3.nx:5000000 add3.nx:10000000 count.nx:… fib.nx:27 fib.nx:30 gcall.nx:…` (`add3.nx`: `(loop [i 0 acc 0] (if (< i n) (recur (inc i) (+ acc i 1 2)) acc))`, kept with the raw output), load 5.1 → 4.6; the `bench/compare` programs by `cmds.py`, five rounds, and their phases, nine interleaved rounds (load 4.2 → 4.1); `run.clj --n 10 --only lang --impls nexis,bb --no-build --max-load 16` four times, after, before, after, before (load 4.0 → 12.8), then `--workloads fib,sort,string-split,vector-conj-nth,destructure` four times, before first (load 12.4 → 10.5); every answer equal. Raw output: `.git/revamp/r2/bench/spd-10/` |
| §3.20 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); babashka v1.13.224; emdb `847c5d8`; shared with concurrent sessions | 2026-10-06 16:13–16:19 MDT, speed integration: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `70db20b` (before) and `35a85bd` (after). Micro kit: `bb bench/micro/run.clj --rounds 7 BEFORE AFTER` under `tools/heavy` (1 core), load 5.05 → 6.58 (a five-round run during the gate, load 6.2 → 7.3, gave the same instructions). Startup: `cmds.py OUT 21` over `-e nil` and `-e '(+ 1 2)'` of each, load 5.94. Language rows: `bb bench/compare/run.clj --out DIR --n 10 --only lang --impls nexis,bb --no-build --max-load 16` four times, after, before, after, before, the binary copied into a worktree of `70db20b`, so each report names that commit (load 5.41 → 5.51); the whole-process counters `cmds.py OUT 5` over each `DIR/src/<row>.nx` (load 5.13 → 5.23). Raw output: `.git/revamp/r2/bench/speed-int/` |
| §3.21 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `847c5d8`; shared with concurrent sessions | 2026-10-06, speed2-v: `bin/nexis` built by `zig build install -Doptimize=fast --prefix DIR` at `f51a5d0` (before) and at each change of the section (after), each against the one before it. Micro kit: `bb bench/micro/run.clj --rounds 5 BEFORE AFTER` under `tools/heavy` (1 core), the load at the start and the end in the text. The `bench/compare` programs (prelude and body) under `/usr/bin/time -l`, five interleaved rounds by `harness.py`, the phase each program reports. The counting-loop figures of the assertion: `bin/nexis run bench/micro/count.nx 10000000`, twelve runs of each build. The database rows: `bb bench/compare/run.clj --n 10 --only db --impls nexis --no-build --max-load 16`, four runs alternating the binary in the worktree's `bin/`. Raw output: `.git/revamp/r2/bench/speed2-v/` |
| §3.13, §6 "Calls from natives" | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds (load average 3–18) | 2026-09-27, ws-pipeline-calls: `bin/nexis` and `nexis-bench` built at `a712a24` (before) and at the branch head (after); `bb bench/compare/run.clj --n 10 --max-load 6 --no-build --workloads pipeline,fib,loop,destructure` four times, after, before, after, before, the binary swapped into one worktree, so each report names the branch head; `zig build bench -Doptimize=ReleaseFast -- --filter vm` five times per build, alternating; the instruction counts from `/usr/bin/time -l bin/nexis run` of the pipeline's program cut after each stage, median of five, the setup's own run subtracted; the per-step figures of §6 from each commit's build against the one before it, the phase timed with `nano-time` inside `bin/nexis run` of the pipeline program, ten runs each, alternating |
| §3.14, §6 "Marking in place", "Results built in place", "A built sequence walked as its vector" and their dead ends | Apple M5, 10 cores, 32 GiB, macOS 27.0, Zig 0.16.0, ReleaseFast; babashka v1.13.224; shared with concurrent builds (load average 3–16) | 2026-09-27/28, ws-pipeline-heap: `bin/nexis` built at `a712a24`, at `8afd353` (main with ws-pipeline-calls) and at the branch head; the cycle and heap figures from a build of `a712a24` with a trace printed at each cycle and at exit; `bb bench/compare/run.clj --n 10 --max-load 6 --no-build --workloads pipeline,map-build-read,map-transient,vector-conj-nth,sort,freq-group` once with `a712a24`, then four times, branch head and `8afd353` alternating, the binary swapped into the branch's worktree, so each report names the branch head; the instruction counts from `/usr/bin/time -l bin/nexis run` of the pipeline program and of its setup alone, five runs each, the median; the trigger table from a build reading the growth and floor from the environment, not committed; the step figures of §6 against the build before each step |
| §3.18, §6 "The stdlib image" | Apple M5, 10 cores, 32 GiB, macOS 27.0.1 (26A434), Zig 0.17.0, ReleaseFast (`-Doptimize=fast`); emdb `847c5d8`; shared with concurrent sessions (load average 3.97 at the start, 3.89 at the end) | 2026-10-06 12:22 MDT, speed-b: `bin/nexis` built by `zig build install -Doptimize=fast` at `b0ba2ae` (before) and `587f87f` (after); `cmds.py OUT 21 'A=… -e nil' 'B=… -e nil'` and the same for `-e '(+ 1 2)'`, under `tools/heavy` (1 core); the load phases from a probe build returning after each phase, five runs each, the median; raw results in the revamp ledger (`bench/speed-b/`) |
| §3.18 the image's verification | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; emdb `847c5d8`; shared with concurrent builds (load average 8.81 at the start, 9.23 at the end) | 2026-10-06 15:55 MDT, speed integration: `bin/nexis` built by `zig build install -Doptimize=fast` at `01e77a0` with the loader's verification, once with it compiled in and once without; `cmds.py OUT 21 'V0=… -e nil' 'V1=… -e nil'` under `tools/heavy` (1 core); raw results in `.git/revamp/r2/bench/speed-int/` |
| §3.19 | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; emdb `847c5d8`; shared with concurrent builds (load average 4–15 at the starts and the ends) | revamp, 2026-10-06, speed-v: `bin/nexis` built by `zig build install -Doptimize=fast` at `305eee3` (one table), `390d571` (fast handlers), `07dd8ce` (`pc` in a register), `b873368` and `1cc9e23` (the hot section), `9bcd928` (verified) and `c4b60cf` (the host's cell), each against the one before it in its own run; `bb bench/micro/run.clj --rounds 5 --programs count,acc,fib,gcall,lc,mv,lv,kw,leaf,getnl` (seven rounds for the hot section and the verified build, fifteen and twenty-five for the rows the text cites, the callback programs for the host's cell) under the machine's core queue, one core; raw JSON in the revamp ledger (`.git/revamp/r2/bench/speed-v/`) |
| §3.19 phase table and language rows | Apple M5, 10 cores, 32 GiB, macOS 27.0.1, Zig 0.17.0, ReleaseFast; emdb `847c5d8`; shared with concurrent builds (load average 4–9) | revamp, 2026-10-06, speed-v: `bin/nexis` of `b0ba2ae` and of `93862af` (`ea38a91` for the language rows), `zig build install -Doptimize=fast`; `bb bench/micro/run.clj --rounds 5` over every program; the language rows' instructions and cycles from `/usr/bin/time -l bin/nexis run` of each `bench/compare` program (prelude and body), one run each; `bb bench/compare/run.clj --no-build --only lang --impls nexis --n 10 --max-load 16` twice per build, alternating, the binary copied into the worktree's `bin/`; the pipeline's phase from its own report, three runs of each build; startup `-e nil` seven runs each; raw output in `.git/revamp/r2/bench/speed-v/` |
