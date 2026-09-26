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
departments, five attributes each (~200k datoms). The integration
tests carry 10k-datom twins that check the row counts
(`test/integration/nextomic_q.zig`, `nextomic_pull.zig`). Each figure
is the best of five invocations, the spread across them in brackets.

| Harness row | What | Time |
|---|---|---:|
| `q_join3_by_dept_2k_rows` | 3-way join by department (`avet` seek → `vaet` → `eavt`), 2000 rows | 0.72 ms to rows [0.72–0.79]; 1.27 ms [1.27–1.37] with the persistent result set |
| `q_join3_by_age` | 3-way join by age (`avet` range → `eavt` → `eavt`), 851 rows | 2.63 ms [2.63–2.76] |
| `q_count_hash_join` | `(count ?e)` by department (`aevt` scan, hash join), 667 rows | 0.43 ms [0.43–0.45] |
| `q_join3_from_1_age` | 3-way join from one age, nested loop, 851 rows | 0.40 ms [0.40–0.42] |
| `q_join3_from_3_ages` | from three ages, nested loop, 2602 rows | 1.33 ms [1.33–1.36] |
| `q_join3_from_7_ages` | from seven ages, hash join on name and salary, 6259 rows | 3.25 ms [3.25–3.44] |
| `pull_many_star` | `pull-many [*]` over 20,000 entities, one read transaction | 12.9 ms [12.9–13.2] |
| `pull_many_nested_ref_limit` | `pull-many` with a nested ref and `:limit`, 20,000 entities | 18.0 ms [18.0–18.3] |
| `pull_reverse_ref_2k` | reverse-ref pull of one department's 2,000 employees | 0.20 ms [0.20–0.22] |

The result sets live on a heap over the process allocator. A profile
of the query rows (`sample` on the ReleaseFast test binary) puts about
30 % of the time in emdb's page search (`page.searchPage`,
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

---

## 6. Levers and dead ends

Each lever is a measured change: a before/after from `zig build bench`
(or a §3.9-style wall-time pair) or it does not land.

**Rows that do not exist.**

- A Clojure comparison suite under BENCH.md, same machine, one row per
  §3 row. Until it exists every Clojure figure here is external.
- Garbage-collection rows: steady-state allocation pressure, pause
  times.
- A memory-footprint row (scorecard #1): peak RSS and allocated bytes
  for a fixed workload.
- A cold-cache random-access `nth` row beside §3.4's sequential one.
- `nexis.simd` and typed-vector rows (scorecard #17).
- Startup (scorecard #18): exec to first result.
- Reruns: §3.1–§3.6 on the machine of §3.7–§3.8, with the emdb
  revision, to settle §3.6's 17×; §3.8's `vm` rows against the
  compiler's shorter loop.

**Levers not built.**

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
| §3.7 | Apple M5, as above | `zig build bench -Doptimize=ReleaseFast -- --filter nextomic`, best of five invocations with the spread; the pull rows took a single sample per run |
| §3.9 | not recorded | revamp, 2026-09-25, ReleaseFast `bin/nexis run`, at the merge of the vector-view change (`7f44db5`) |
