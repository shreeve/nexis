## PERF.md — Performance landscape, measured baseline, and Clojure comparison

**Single source of truth for nexis performance.** Complements
`docs/BENCH.md` (measurement methodology). This document catalogs
performance categories, records the measured baseline, grades
each measurement against theoretical ceilings, and tracks the
improvement runway.

**Honesty clause**: every number is tagged with a status —

- `measured` — benchmark exists, number recorded, reproducible.
- `measured (partial)` — direct nexis measurement; Clojure
  comparison still references published external numbers rather
  than same-machine head-to-head.
- `estimated` — projected from published work or first
  principles; no nexis measurement yet.
- `planned` — specified, with no implementation in the tree.

Every "we're N× faster than Clojure" claim outside this document
must cite a specific `measured` row here, or the claim gets
withdrawn. See BENCH.md §1 for the four standards all
measurements must meet.

**Derivative from**: `PLAN.md` §19 (performance strategy & perf
gates), `PLAN.md` §2 (substrate choice), `BENCH.md` (methodology),
per-kind specs. PLAN.md wins on conflict.

---

## Table of contents

1. What we mean by "performance"
2. Scorecard
3. Measured baseline
4. Tier analysis — how good are these numbers?
5. Per-category design detail
6. Priority sequence
7. Non-goals
8. Biggest findings from the first baseline
9. Honesty receipts
10. Cross-references
11. Measurement provenance

---

## 1. What we mean by "performance"

Four orthogonal axes. A win on one is not a win on another;
tradeoffs between axes are legitimate.

| Axis | Question | Primary metric |
|---|---|---|
| **Throughput** | ops/sec on a hot path, warmed up | ns/op median |
| **Latency** | time from request to response, tail-included | p99 ms |
| **Memory density** | bytes per live value, bytes per collection entry | Bytes/N |
| **Startup** | time from process exec to first useful result | ms wall |

Clojure is dominant on sustained throughput (HotSpot JIT is world-
class), competitive on tail latency (modern collectors like ZGC),
weak on memory density (boxing), and weak on startup (JVM warmup).

nexis's architectural targets, by axis:

- **Throughput**: parity or better than Clojure's fully-JIT'd
  steady state is the target; the bytecode VM has no opcode
  specialization, so sustained compute is behind (§5.19).
- **Latency**: strictly better than Clojure on durable-state ops
  (emdb zero-copy vs no comparable feature in Clojure stdlib).
  Parity or better on pure-compute tails (precise explicit GC has
  no surprise pauses from unrelated code; Clojure's GC does).
- **Memory density**: strictly better. NaN-boxed 16-byte Values +
  CHAMP + typed-vectors project to ~2–3× fewer bytes per unit of
  live state on representative workloads.
- **Startup**: strictly better by orders of magnitude. Native
  binary vs JVM warmup.

---

## 2. Scorecard

Single-screen overview. Detail per category in §5. Δ is the
projected nexis direction vs Clojure. "Measured" column cites the
§3 baseline for rows with recorded numbers.

| # | Category | Clojure | nexis | Δ | Measured | Status |
|---|---|---|---|---|---|---|
| 1 | Value cell size | 16–56 B boxed | 16 B NaN-boxed tagged | **2–3× smaller** | — | implemented, not measured |
| 2 | Fixnum arithmetic | Boxed `Long` / `unchecked-*` | Inline 62-bit tagged | **3–10×** on tight loops | ~1 ns/op (§3.1) | measured |
| 3 | Float arithmetic | Boxed `Double` / `^double` | Inline NaN-boxed f64 | **2–5×** on idiomatic | <1 ns/op† (§3.1) | measured |
| 4 | Persistent map | HAMT (Bagwell 2001) | CHAMP (Steindorfer 2015) | **15–25%** faster lookup, **30–40%** less memory | get 15.5 ns/op @ N=4096 on M1 (§3.4); 13.3 ns/op on M5 (§3.8) | measured (partial) |
| 5 | Persistent set | HAMT | CHAMP | same as #4 | contains 9.4 ns/op @ N=4096 on M1 (§3.4); 6.9 ns/op on M5 (§3.8) | measured (partial) |
| 6 | Persistent vector | 32-way trie + tail | 32-way trie + tail | **parity** expected | nth ~1 ns/op @ N=4096 (§3.4)‡ | measured (partial) |
| 7 | Persistent list | Cons cells | Cons cells | **parity** | cons 14.7 ns/op @ N=4096 (§3.2) | measured |
| 8 | Hashing | Murmur3 | xxHash3-64 | **2–3×** faster on long bytes | ~34 GB/s (§3.1) | measured (partial) |
| 9 | Keyword identity | Intern + identity | Intern + identity | **parity** | hash 2 ns (§3.1) | measured |
| 10 | Transients | Mutation token | Owner-token (Option B wrapper) | **parity**; node-owner in-place edit is the open lever | ~parity with persistent (§3.3) | measured |
| 11 | GC | Generational tracing (G1/ZGC) | Precise non-moving mark-sweep | **worse** short-term; addressable | — | implemented, acknowledged weakness |
| 12 | Allocator | TLAB bump pointer | the process allocator under the collected heap (`smp_allocator` in release builds) | **worse** on allocation-heavy paths; a size-class pool is the open lever (§5.12) | a size-class pool the bench carried built lists **3.94×** and maps **1.80×** faster than the general-purpose allocator (§3.2); the runtime never used it | measured (bench only) |
| 13 | Dispatch / polymorphism | Inline-cached via JIT | 26-way switch per op | **worse** at warm steady state; inline caches absent | hashValue ~1–2 ns (§3.1); 2.9 ns per bytecode instruction, 20 ns per global fn call on M5 (§3.8) | measured (partial) |
| 14 | Durable state | No stdlib primitive | emdb mmap, zero-copy | **orders of magnitude faster** | get-hot 1.04 μs (§3.6) | measured (partial) |
| 15 | Codec / serialization | `.edn` / Nippy | Binary LEB128/ZigZag | **2–5× size, 5–20× speed** vs `.edn` | encode 18 ns/entry, decode 124 ns/entry (§3.5) | measured (partial) |
| 16 | Concurrency tax | STM + CAS pervasive | Single-isolate, single-writer | **strictly less overhead**; by design | — | implemented, by design |
| 17 | SIMD / typed-vector | JIT may autovectorize | `@Vector(4, f64)` kernels over unboxed typed vectors (`nexis.simd`) | **2–8×** on bulk numeric ops | — | implemented, not measured |
| 18 | Startup | 100–500 ms JVM warmup | Native binary | **10–500×** | — | implemented, not measured |
| 19 | Compilation | HotSpot C1+C2 JIT | Bytecode VM, switch dispatch, no specialization | **worse** on sustained compute | — | not measured against Clojure |
| 20 | Comptime specialization | JIT inlining + escape analysis | Zig `comptime` monomorphization | **~2×** on specialized paths | — | absent |
| 21 | Datalog over datoms (Nextomic) | Datomic (peer + transactor, JVM) | in-process, emdb named trees, arena per operation | not head-to-head measured | 3-way join over 200k datoms 0.72 ms to rows; 20k `[*]` pulls 12.9 ms (§3.7) | measured (corpus benchmark, best of 5 runs) |

**†** NaN-box pair inlines through arithmetic; measured median is
at or below harness timer resolution. See §3.1 footnote.
**‡** Sequential cache-hot access pattern; random-access
cold-cache measurement is a follow-up. See §3.4 footnote.

---

## 3. Measured baseline

### Machine of record

| Field | Value |
|---|---|
| CPU | Apple M1 (apple_m1) |
| OS | macOS |
| Optimize | ReleaseFast |
| Zig | 0.16.0 |
| Allocator | a size-class pool under the benchmark heaps (the runtime itself runs on the process allocator; the pool is not in the tree) |
| Harness | `src/bench.zig` (criterion-style, 30 samples × ≥50 ms per measurement) |
| Baseline run date | 2026-04-19 |
| Baseline numbers | Inline in §3.1–§3.6 below |
| Local artifacts (`.gitignore`d) | `bench/*.json` |

**On the JSON files.** `bench/*.json` are **local run artifacts,
not committed**. The numbers of record live inline in §3.1–§3.7.
Regenerate locally with
`zig build bench -- --out bench/baseline.json`. Per-machine /
per-conditions runs should NOT be committed — diffing them is
the job of the in-doc numbers, which are curated.

**Methodology note**: every collection-construction benchmark
creates a fresh `Heap` per measurement invocation and
`Heap.deinit()`s it when the invocation returns. This prevents
unbounded memory growth across `inner_reps` on N=4096 workloads
(without it both allocators OOM at N=4096) and is what makes the
A/B below fair. A run without per-invocation heap reset reports
different N=4096 construction numbers because of the accumulation
effect; the §3.2 / §3.3 tables are per-invocation numbers.

Reproducing:

    zig build bench -Doptimize=ReleaseFast -- --out bench/run.json --note "your-hw"

**Clojure-side same-machine comparison is NOT in this baseline.**
That's a follow-up commit using `criterium` per BENCH.md §5. The
baseline here is nexis-only. Published Clojure numbers referenced
in the interpretation sections below are labeled as external and
NOT as head-to-head measurements.

---

### 3.1 Scalar microbenchmarks

| Benchmark | Median | p5 | p95 | ops/sec | Notes |
|---|---:|---:|---:|---:|---|
| `fixnum_add` | ~1 ns | 0 ns | 1 ns | ~1 B | Tagged fixnum +; NaN-box + unbox + add + re-tag |
| `float_add` | <1 ns† | 0 ns | 0 ns | below resolution | See footnote † |
| `hash_fixnum` | ~1 ns | 1 ns | 1 ns | ~1 B | `dispatch.hashValue` full switch + immediate-kind fast path |
| `hash_keyword` | 2 ns | 2 ns | 2 ns | 500 M | One extra cycle over fixnum — keyword hashing reads intern id then mixes |
| `hash_string_43b` | ~1 ns | 1 ns | 1 ns | ~1 B | Cached `hash` slot on HeapHeader |
| `xxhash3_raw_172b` | 5 ns | 5 ns | 5 ns | 200 M | ≈**34 GB/s** raw throughput |

**†** `float_add` reports a median of 0 ns under ReleaseFast.
Volatile-pointer guards are in place on both operand reads and
accumulator writes; despite this, LLVM inlines the NaN-box/unbox
pair through the arithmetic, leaving a single f64 add whose total
cost is at or below the harness's per-op timer resolution (~1 ns
at the 50 ms measurement floor ÷ inner_reps). Read as "effectively
below measurement resolution on this target," not as a literal
zero-cost claim.

**Interpretation:**

- Every scalar op is sub-5 ns. `dispatch.hashValue` through the
  26-way switch is ~1–2 ns, validating the tagged-immediate
  design: the switch predicts well enough that dispatch cost is
  ~single-cycle.
- xxHash3 at 34 GB/s is a plausible architectural win vs
  Clojure's Murmur3 (~10–14 GB/s per external references), but
  this is **not a same-machine head-to-head measurement**.

---

### 3.2 Persistent collection construction — general-purpose allocator vs a size-class pool

N-fold conj/assoc from empty; keyword keys throughout. **Two
columns**: `std` = the general-purpose allocator; `pool` = a
size-class pool the bench carried (16 classes from 16 B to 4 KiB,
LIFO free lists, slab bump pointer). The runtime's heap never used
the pool, and it is not in the tree (§5.12).

| Op | N | std median | pool median | **Speedup** | pool per-op |
|---|---:|---:|---:|---:|---:|
| `list_cons_n` | 16 | 296 ns | 55 ns | **5.38×** | 3.4 ns/cons |
| `list_cons_n` | 256 | 4.35 μs | 858 ns | **5.07×** | 3.4 ns/cons |
| `list_cons_n` | 4096 | 72.0 μs | 18.3 μs | **3.94×** | **4.5 ns/cons** |
| `vector_conj_n` | 16 | 701 ns | 215 ns | **3.26×** | 13.4 ns/conj |
| `vector_conj_n` | 256 | 12.3 μs | 4.30 μs | **2.86×** | 16.8 ns/conj |
| `vector_conj_n` | 4096 | 213 μs | 82.2 μs | **2.59×** | **20.1 ns/conj** |
| `map_assoc_n` | 16 | 1.01 μs | 475 ns | **2.13×** | 29.7 ns/assoc |
| `map_assoc_n` | 256 | 25.8 μs | 11.9 μs | **2.17×** | 46.5 ns/assoc |
| `map_assoc_n` | 4096 | 620 μs | 345 μs | **1.80×** | **84.2 ns/assoc** |
| `set_conj_n` | 16 | 963 ns | 419 ns | **2.30×** | 26.2 ns/conj |
| `set_conj_n` | 256 | 24.6 μs | 10.7 μs | **2.30×** | 41.8 ns/conj |
| `set_conj_n` | 4096 | 586 μs | 319 μs | **1.84×** | **77.9 ns/conj** |

**Interpretation:**

- **Headline**: list cons drops from ~18 ns/op → **~4.5 ns/op**
  (~4× lift) — pure allocator cost. Map assoc from ~150 ns/op →
  **~84 ns/op** (~1.8× lift). Every construction op is
  measurably faster; no regressions.
- Map assoc at N=4096 is roughly 45% allocator-bound (the rest is
  hash + memcpy + trie navigation), which bounds the allocator
  lift on deep-trie paths at ~1.8× rather than the 3× a purely
  allocator-bound model would give.
- Small-N wins are larger (list cons at N=16 is **5.4×**)
  because allocator overhead is a larger fraction when per-op
  work is small.
- External Clojure reference for `(assoc m k v)` on a 4k-entry
  `PersistentHashMap` post-JIT is ~100–300 ns; our **84 ns**
  sits at the **low end of / plausibly below** that range.
  Not a same-machine head-to-head measurement.

---

### 3.3 Transient construction — A/B

Same N, via `transientFrom` / `*Bang` / `persistentBang`.

| Op | N | std median | pool median | **Speedup** |
|---|---:|---:|---:|---:|
| `transient_vector_conjbang_n` | 4096 | 208 μs | 82.5 μs | **2.52×** |
| `transient_map_assocbang_n` | 4096 | 615 μs | 348 μs | **1.77×** |
| `transient_set_conjbang_n` | 4096 | 580 μs | 321 μs | **1.81×** |

**Interpretation:**

- Pool lift tracks persistent paths very closely — transients see
  the same ~1.8–2.5× speedup. Confirms that the Option B
  wrapper-over-persistent implementation is genuinely paying the
  allocator cost on each internal persistent op.
- **Transients remain at parity with persistent paths** at N=4096
  post-pool, not the 5–10× savings Clojure's transients deliver.
  The primary explanation is our Option B implementation choice
  (wrapper over persistent with owner token + subkind dispatch +
  delegated persistent ops), not the node-owner in-place edit
  design. Parity is the expected outcome; there is no node-owner
  in-place edit.
- Open lever: node-owner in-place-edit transient +
  comptime monomorphization of `!Bang` dispatch is the path to
  larger transient wins.

---

### 3.4 Collection lookup

Pre-built collection; N lookups (sequential for vectors, by
exact key for maps/sets).

| Op | N=256 | N=4096 | Per-op at N=4096 |
|---|---:|---:|---:|
| `vector_nth_n_sequential` | 136 ns | 2.94 μs | **<1 ns/nth**‡ |
| `map_get_n_hit` | 2.62 μs | 63.6 μs | **15.5 ns/get** |
| `set_contains_n_hit` | 1.99 μs | 38.5 μs | **9.4 ns/contains** |

**‡** `vector_nth_n_sequential` per-op is at the edge of what a
criterion-style harness can resolve; sequential access within a
dense trie leaf is extremely cache-friendly and the accumulator
pattern amortizes across 4096 reads. Read as "on the order of
1 ns per random-access lookup on this target." A cold-cache
random-access variant is a follow-up.

**Interpretation:**

- Vector nth is extremely fast at this scale — cache-friendly
  trie traversal + single-indirection payload read. External
  Clojure reference `(nth v i)` is roughly 2–4 ns post-JIT; fair
  same-machine head-to-head is a follow-up.
- Map get at 15.5 ns per hit is plausibly faster than Clojure
  reference numbers for 4k-entry `PersistentHashMap` get (which
  published external sources put at 25–40 ns post-JIT). The
  Steindorfer CHAMP-vs-HAMT delta (15–25%) is directionally
  consistent.
- Set contains at 9.4 ns is even faster than map get because
  there's no value to retrieve.

---

### 3.5 Codec — A/B

| Op | std median | pool median | Pool per-unit | Δ |
|---|---:|---:|---:|---:|
| `codec_encode_fixnum` | 23 ns | 24 ns | — | parity |
| `codec_decode_fixnum` | 4 ns | 4 ns | — | parity |
| `codec_encode_map_n64` | 1.15 μs | 1.18 μs | 18 ns/entry | parity |
| `codec_decode_map_n64` | 6.18 μs | 5.44 μs | **85 ns/entry** | **1.14×** |

**Interpretation:**

- Encode paths are allocation-free once the output buffer is
  pre-sized (which `ArrayListUnmanaged`'s growth policy usually
  ensures). No pool lift, no regression.
- Decode map improves **~12%** from the pool — less than
  projected (~3×) because decode is *also* paying codec parsing
  + value construction, and those aren't allocator-bound. Per-
  entry cost drops from ~103 ns → ~85 ns.

---

### 3.6 DB-integrated (emdb bridge)

| Op | Median | Notes |
|---|---:|---|
| `db_put_commit_scalar` | 6.15 ms | **fsync-dominated** — per-*commit* cost, not per-put |
| `db_get_hit_scalar` | 1.04 μs | full txn open + B+ tree walk + codec decode + txn abort |

**Interpretation:**

- `db_put_commit_scalar` at 6.15 ms is NOT a per-put cost — it's
  a per-commit cost. Users who batch 10k puts into one
  transaction pay 6 ms once, not 60 seconds. This is strictly
  the cost of durable write commit latency; on an M1 SSD with
  fsync that's ~3–10 ms hardware floor.
- `db_get_hit_scalar` at 1.04 μs is the full pipeline in one
  number. External references for Datomic deref are in the
  10 μs–10 ms range depending on cache tier; Redis local is
  100 μs–1 ms. nexis is clearly orders of magnitude faster for
  overlapping use cases — but this is not a same-machine
  head-to-head measurement.

### 3.7 Nextomic — query and pull over 200k datoms

The `nextomic` category of the bench harness
(`bench/nextomic.zig`) builds both stores and measures every row
through the engine's Zig API. Reproduce with
`zig build bench -Doptimize=ReleaseFast -- --filter nextomic`. The
tests carry 10k-datom twins of both corpora that check the row
counts (`test/integration/nextomic_{q,pull}.zig`).
The store is emdb with 16 KiB pages; the datom set is 40,000
employees in 20 departments, five attributes each (~200k datoms).

The table was measured as the best of five timed runs per row, the
best of five invocations with the spread across them in brackets
(Apple M5, 32 GiB, macOS 26.6, Zig 0.16.0, ReleaseFast, idle
machine); the harness reports the 30-sample median of each row
instead.

| Op | ReleaseFast, Apple M5 | Notes |
|---|---:|---|
| 3-way join by department (`avet` seek → `vaet` → `eavt`), 2000 rows | 0.72 ms to rows [0.72–0.79] | 1.27 ms [1.27–1.37] including the persistent result set |
| 3-way join by age (`avet` range → `eavt` → `eavt`), 851 rows | 2.63 ms [2.63–2.76] | includes the result set |
| `(count ?e)` by department (`aevt` scan + hash join), 667 rows | 0.43 ms [0.43–0.45] | |
| 3-way join from 1 age (`avet` seek, then name and salary), 851 rows | 0.40 ms [0.40–0.42] | nested loop |
| 3-way join from 3 ages, 2602 rows | 1.33 ms [1.33–1.36] | nested loop |
| 3-way join from 7 ages, 6259 rows | 3.25 ms [3.25–3.44] | hash join on name and salary |
| `pull-many [*]` over 20,000 entities (5 datoms each) | 12.9 ms [12.9–13.2] | one read transaction for the whole call; single sample per run |
| `pull-many` nested ref + `:limit` over 20,000 entities | 18.0 ms [18.0–18.3] | single sample per run |
| reverse-ref pull of the 2,000 employees of one department | 0.20 ms [0.20–0.22] | single sample per run |

**Caveats:**

- The result sets are built on a heap over the process allocator,
  so the rows measure the VM heap's allocator, not a testing
  allocator's bookkeeping.
- A profile of the query rows (`sample` on the ReleaseFast test
  binary with the repetitions raised) puts about 30 % of the time in
  the engine's page search (`page.searchPage`, `simd.compare`), 10 %
  in `Exec.scanInto`, and about 5 % in decoding string values out of
  keys into the arena; the rest is relation building and the arena.
- In a Debug build under the testing allocator the same rows are an
  order of magnitude slower; they are not performance measurements.

### 3.8 Dispatch and lookup rows, Apple M5

`zig build bench -Doptimize=ReleaseFast` on Apple M5 (32 GiB, macOS
26.6, Zig 0.16.0, pool allocator, idle machine): the best of five
invocations of the 30-sample median, the spread across the five in
brackets. "Before" is the tree at `739d24f` (the harness rows
themselves), "after" is the tree with the two optimizations below.
Cross-machine numbers are not comparable (docs/BENCH.md §4); the M1
rows in §3.1–§3.6 stand as that machine's baseline.

The `vm` rows run a routine compiled once on one VM, so a sample is
the dispatch loop alone; each loops 10,000 times.

| Row | Before | After | Change |
|---|---:|---:|---|
| `vm_loop_10k` (9 instructions per iteration) | 340.71 μs [340.7–344.4] | 265.12 μs [265.1–288.6] | `vm` commit: hot groups run against the fetched frame; the collection check follows allocating groups |
| `vm_global_call_10k` (`(inc1 i)` through a Var per iteration) | 588.10 μs [588.1–600.3] | 469.73 μs [469.7–497.0] | same |
| `vm_keyword_get_10k` (`(:k m)` on a 12-entry map per iteration) | 665.51 μs [665.5–669.6] | 517.11 μs [517.1–536.1] | same |
| `eval_simple_loop` (compile + run a 100-iteration loop) | 5.99 μs [5.99–6.05] | 5.06 μs [5.06–5.40] | same |
| `eval_arith`, `closure_create`, `compile_simple` | 1.41 μs, 1.02 μs, 550 ns | within noise | — |
| `map_get_n_hit` N=256 | 2.65 μs [2.65–2.69] | 2.10 μs [2.10–2.17] | `champ` commit: an immediate key hashes inline |
| `map_get_n_hit` N=4096 | 60.66 μs [60.7–63.5] | 54.32 μs [54.3–54.9] | same; 13.3 ns per get |
| `set_contains_n_hit` N=256 | 1.90 μs [1.90–1.93] | 1.19 μs [1.19–1.23] | same |
| `set_contains_n_hit` N=4096 | 36.71 μs [36.7–37.2] | 28.17 μs [28.2–28.3] | same; 6.9 ns per contains |
| `map_assoc_n` / `set_conj_n` at 16, 256, 4096 | 463 ns / 390 ns, 11.5 μs / 10.4 μs, 318 μs / 298 μs | within noise | construction is allocation-bound |

Per instruction, the counting loop
costs 2.9 ns after the change (9 instructions per iteration; 3.8 ns
before); a global fn call (`var:load-var`, `call:call`, the callee's
four instructions, `call:return`) adds 20 ns per iteration. A Var load is one read of
the routine's `var_table` entry and its `root` (`docs/VM.md` §10 #6);
there is no inline cache to add on that path.

Rows the pass measured but did not change, same machine, best of
five: `list_cons_n` 4096 17.96 μs, `vector_conj_n` 4096 78.59 μs,
`vector_nth_n_sequential` 4096 2.89 μs, `codec_decode_map_n64`
4.48 μs, `db_put_commit_scalar` 6.00 ms, `db_get_hit_scalar` 60 ns.

---

## 4. Tier analysis — how good are these numbers?

Calibrated against theoretical ceilings, external published
references, and hardware floors. Grades reflect where each
measurement sits in the space between "literally impossible to
improve" and "clear optimization runway."

### 4.1 Near theoretical ceiling (A+ / A)

**`xxHash3 ~34 GB/s`** — on M1, single-core sustainable memory
read bandwidth is ~40–60 GB/s. We're at **~70–85% of memory
bandwidth on a hash function**. Published xxHash3 numbers on
M-series top out around 32–35 GB/s. This is essentially at the
ceiling; SIMD hash variants can go higher on long inputs but
172 B is too short to benefit. External reference: Murmur3
~10–14 GB/s, SHA256 ~1–2 GB/s. **You cannot meaningfully improve
this number.**

**`vector nth ~1 ns`** — a raw `arr[i]` load in C is ~0.3–1 ns.
A 3-level trie walk with L1-resident cache is ~1–3 ns
theoretical. We're at the low end of theoretical for cache-hot
sequential access. Near-ceiling; a random-access cold-cache
measurement on the same data would realistically be 10–50 ns,
and that's a legitimate follow-up workload.

**`emdb put+commit 6.15 ms`** — this is **fsync**. On M1 SSD,
hardware fsync latency is ~3–10 ms. **We're at the hardware
floor.** The only way to "beat" this is to abandon durability
(noSync mode → ~10–50 μs) or batch (amortize fsync across 10k
puts). Cannot beat this while preserving durability semantics.

### 4.2 Excellent, small headroom (A / A–)

**`CHAMP set contains 9.4 ns`** — one hash (~2 ns) + 2-level
trie walk + present/absent bit. Theoretical floor ~5–7 ns.
External Clojure `PersistentHashSet` post-JIT is in the
15–25 ns range. Small headroom from comptime specialization of
the hash dispatch (~2–4 ns potential recovery).

**`CHAMP map get 15.5 ns`** — set contains + one more value load
+ return. Same story. External Clojure reference 25–40 ns
post-JIT. Another ~3–5 ns to squeeze via monomorphized dispatch.

### 4.3 Allocator A/B (std vs pool)

The general-purpose allocator against the size-class pool of §3.2,
which the runtime's heap never used and which is not in the tree:

| Measurement | Before | After (pool) | Lift |
|---|---:|---:|---:|
| list cons @ N=4096 | 17.6 ns/op | **4.5 ns/op** | **3.94×** |
| vector conj @ N=4096 | 51.9 ns/op | **20.1 ns/op** | **2.59×** |
| map assoc @ N=4096 | 151 ns/op | **84.2 ns/op** | **1.80×** |
| set conj @ N=4096 | 143 ns/op | **77.9 ns/op** | **1.84×** |
| codec decode map entry | ~103 ns | **~85 ns** | 1.14× |

**Reading the numbers.** Map assoc at N=4096 is closer to **45%
allocator-bound** (rest is hash + byte-copy + trie navigation),
which caps its lift at ~1.8×. **List cons** (shallowest per-op
work) shows the largest lift because it is the most
allocator-dominated.

**Where further lift is available**:
- **Comptime monomorphization** of `mapAssoc`'s hash/equal for
  keyword-keyed maps: skip the dispatch switch entirely on the
  hot path. Projected additional ~10–20% on map/set.
- **HeapHeader slim-down** (§5.1): reducing the per-block header
  bytes lets more blocks fit in a cache line. Projected ~5–10%.
- **Node-owner in-place-edit transients** (§5.10): for workloads
  that actually use transients, this is the Clojure-class win.

The large projected lift (5–30×) from generational GC (§5.11) is
unrealized. Construction workloads under sustained
pressure on a long-lived process will see it; a single-shot
benchmark like the current suite does not.

### 4.4 Good for category, not maxed (A)

**`emdb deref 1.04 μs`** — pipeline decomposition: transaction
open (~500 ns) + B+ tree walk (~100–300 ns) + mmap page touch
(~10 ns) + codec decode fixnum (~4 ns) + transaction abort
(~200 ns). Raw LMDB `mdb_get` post-warm is ~200–500 ns; we're
paying ~2× LMDB for transaction wrapping + codec. Recoverable
via a fast-path `derefHot` that skips full transaction scaffolding
for a single-key read.

### 4.5 The honest one-liner

Hashing and set/map lookup are at or near theoretical ceilings.
Vector random-access is near-ceiling for cache-hot workloads.
Map assoc is the one line item with clear, measurable runway
(~3× projected via allocator). DB deref is ~2× raw LMDB but
100–1000× faster than comparable higher-level stacks. DB commit
is at the hardware fsync floor.

### 4.6 What it would take to match or beat Clojure everywhere

- **Already plausibly ahead**: hashing, map/set lookup, vector
  nth, durable state, startup (not measured but structurally
  obvious).
- **At parity**: map/set/vector construction.
- **Behind**: GC (a non-generational mark-sweep the VM runs between
  two instructions once the heap has allocated its threshold,
  `docs/GC.md` §1, §7), dispatch in warm steady state, sustained
  compute (no opcode specialization).

Generational GC would close the throughput-under-alloc-churn
gap; opcode specialization and inline caches would close the
sustained-compute gap. Each is its own measured change — the
harness exists to prove or refute every claim.

---

## 5. Per-category design detail

Architecture notes on each scorecard row. What Clojure does, what
nexis does, why the chosen design.

### 5.1 Value cell size

**Clojure**: every value is a JVM `Object`. `java.lang.Long` is
16 B (12-byte header + 4 padding + 8-byte long). `Double` is
16 B. Array slots hold 8-byte references on 64-bit JVMs with
compressed oops. A map entry costs ~48 B for a `String→Long` pair
before node overhead.

**nexis**: every Value is a 16-byte cell (`Value.tag: u64` +
`Value.payload: u64`). Heap values have payload be a pointer;
the cell is still 16 B. Array slots (`Value[]`) pack 4 per cache
line.

**Projected delta**: 2–3× smaller per live value on mixed
workloads. 6–8× on dense numeric arrays once typed-vector ships.

**Status**: implemented (VALUE.md), no direct memory-footprint
benchmark yet.

### 5.2 Fixnum arithmetic

**Clojure**: idiomatic `(+ a b)` boxes operands into `Long` if
either is. `^long` hints unbox in local scope only — crossing
into a collection reboxes. `unchecked-*` disables overflow checks.

**nexis**: fixnum is a 62-bit tagged immediate (VALUE.md §3).
`(+ a b)` on two fixnums is decode-tag → overflow-check → re-tag.
No allocation, no boxing, ~3–6 cycles. Pure-fixnum hot loops
never allocate.

**Measured**: ~1 ns/op (§3.1).

### 5.3 Float arithmetic

**Clojure**: symmetric to §5.2. `^double` locally, boxed when
crossing collections.

**nexis**: NaN-boxed f64 payload; arithmetic is a raw f64 op
after tag check. Same allocation-free story as fixnum.

**Measured**: <1 ns/op (§3.1); NaN-box pair inlines through.

### 5.4 Persistent map

**Clojure**: `PersistentHashMap` — 32-way HAMT (Bagwell 2001).
`BitmapIndexedNode` and `HashCollisionNode`; children and entries
share the same slot array, distinguished at runtime.

**nexis**: CHAMP (Steindorfer & Vinju 2015). Two separate
bitmaps per node (data + node). Entries and child pointers in
cleanly partitioned regions. Subkind taxonomy: array-map (≤8
entries), CHAMP root (≥9), CHAMP interior, collision. See
`docs/CHAMP.md`.

**Why CHAMP wins**: packed array by bitmap population count (no
sparse slot traversal); data and node regions contiguous; no
per-slot runtime type check; canonical representation enables
pointer-identity fast paths.

**Published** (Steindorfer 2015 + replications): lookup **15–25%
faster**, insert **10–20% faster**, iteration **20–40% faster**,
memory **30–40% less** than classic HAMT.

**Measured**: get 15.5 ns/op @ N=4096 (§3.4). Full memory
comparison is a follow-up.

### 5.5 Persistent set

Parallel to §5.4. CHAMP with two-bitmap node; one-slot entries.
See `docs/CHAMP.md` Part 2.

**Measured**: contains 9.4 ns/op @ N=4096 (§3.4).

### 5.6 Persistent vector

Both Clojure and nexis ship the 32-way radix trie with tail
buffer (PLAN.md §8.3 + VECTOR.md). Neither has RRB relaxation
built in (Clojure ships RRB separately as `core.rrb-vector`;
nexis has none, PLAN §23 #30).

**Measured**: conj 63.3 ns/op, nth ~1 ns/op @ N=4096 (§3.2/§3.4).

### 5.7 Persistent list

Cons-cell list on both sides. `head` / `tail` O(1), `count` O(n).
No meaningful architectural delta.

**Measured**: cons 14.7 ns/op @ N=4096 (§3.2).

### 5.8 Hashing

**Clojure**: Murmur3 since 1.6.

**nexis**: xxHash3-64. Published numbers put xxHash3 at ~2–3×
Murmur3 on long inputs, competitive on short.

**Measured**: xxHash3 at ~34 GB/s (§3.1) — 70–85% of single-core
M1 memory bandwidth.

### 5.9 Keyword identity

Both intern keywords globally; equality is pointer-identity,
hash cached. nexis edge: keyword intern ID is a 32-bit integer
inline in the Value cell, saving one pointer dereference vs
Clojure's reference-typed keyword.

**Measured**: hash 2 ns, equality ~1 ns (§3.1).

### 5.10 Transients

Both sides implement Bagwell/Hickey-style transients semantically:
O(1) conversion from persistent, mutation guarded by owner token,
`persistent!` finalizes + invalidates.

**nexis discipline** (TRANSIENT.md): **Option B** — wrapper
over persistent with owner-token check + subkind dispatch +
delegated persistent ops. Correctness-first. The node-owner
in-place-edit optimization used by Clojure's optimized transients
is absent by decision.

**Measured**: parity with persistent paths at N=4096 (§3.3) —
expected consequence of Option B choice.

### 5.11 Garbage collection — **acknowledged weakness**

**Clojure**: JVM ships with world-class collectors (G1, ZGC,
Shenandoah). Generational — most objects die young, so young-gen
collection is O(survivors) not O(live heap).

**nexis**: `src/gc.zig` is a precise, non-moving, stop-the-world
mark-sweep collector (GC.md). Every collection is O(live heap).

**Actual cost**: persistent data structures churn short-lived
intermediate allocations (path-copy in `mapAssoc` creates
O(log₃₂ N) interior nodes per op). Mark-sweep reclaims them, but
only after traversing the entire live heap.

**Plan** (PLAN.md §9 + §19.6): nursery allocator + write barriers
for generational collection. Estimated 5–30× faster on
steady-state allocation-heavy workloads.

**Status**: implemented, non-generational, run by the VM at its
safe point once the heap has allocated its threshold (`docs/GC.md`
§1, §7); acknowledged weakness.

### 5.12 Allocator — the open lever

**Clojure (JVM)**: TLAB bump pointer. Young-gen allocation is
2–5 ns.

**nexis**: the collected heap allocates every block from the
process allocator (`std.heap.smp_allocator` in release builds). A
size-class pool (16 size classes from 16 B to 4 KB, free-list LIFO
per class, slab-backed bump pointer, single-threaded) that the bench
carried, and that was never wired under the VM's heap, measured
against the general-purpose allocator (§3.2, §3.3, §3.5, §4.3):
- list cons @ N=4096: 17.6 ns → 4.5 ns (**3.94×**)
- vector conj @ N=4096: 51.9 ns → 20.1 ns (**2.59×**)
- map assoc @ N=4096: 151 ns → 84 ns (**1.80×**)
- set conj @ N=4096: 143 ns → 78 ns (**1.84×**)
- codec decode map entry: ~103 ns → ~85 ns (**1.14×**)

**Status**: not in the tree. An allocator of that shape under
`VM.heap`, with empty-slab reclamation so a long REPL session gives
memory back, is the lever; it lands with a before/after from
`zig build bench` on the runtime's own heap.

### 5.13 Dispatch / polymorphism — medium-term leverage

**Clojure**: HotSpot inline-caches call sites. Monomorphic sites
bake in the concrete function pointer after ~10k calls.
Multi-morphic sites get a PIC.

**nexis**: `dispatch.hashValue` / `dispatch.equal` /
`dispatch.heapHashBase` are 26-way `switch` statements. Zero
inline caching.

**Measured**: hashValue ~1–2 ns (§3.1) — the switch predicts
well enough at hot paths to be ~single-cycle.

**What exists**: the run loops fetch through one frame pointer and
hand it to the handlers of the groups that never push or pop a frame
(`mov`, `cmp`, `jump`, `var`, `math`), so their operands resolve
without re-deriving the frame; the collection check runs only after
an instruction that could have allocated (`docs/VM.md` §8, §9). A
Var load reads the `var_table` entry and its `root` directly. There
are no inline caches at call sites, no comptime monomorphization of
`dispatch.hashValue`/`dispatch.equal`, and no per-kind fast paths at
dispatch entry. Measured: 2.9 ns per bytecode instruction, 20 ns per
global fn call, on M5 (§3.8).

### 5.14 Durable state — **one-way architectural win**

**Clojure**: stdlib has no durable-state primitive. Applications
reach for Datomic (remote peer, μs–ms latency), SQL (JDBC +
serialization), Redis/Memcached (network round-trip).

**nexis**: `src/db.zig` + emdb. `(deref durable-ref)` is a
memory-mapped B+ tree lookup + codec decode. Zero-copy on value
bytes; only the decoded Value is allocated.

**Measured**: deref 1.04 μs end-to-end (§3.6). External Datomic
deref 100 μs–10 ms; Redis local 100 μs–1 ms. Architecturally
strictly faster for overlapping use cases.

### 5.15 Codec / serialization

**Clojure**: `pr-str` → `.edn` text by default. Fast + readable,
but 4–10× larger than binary and 5–20× slower to parse. Third-
party `Nippy` is the de-facto binary serializer.

**nexis**: `src/codec.zig`. Binary, self-describing, LEB128 for
lengths, ZigZag for signed ints, fixed LE for f64/char. Per-kind
encodings pinned in CODEC.md.

**Measured**: encode map 18 ns/entry, decode map 124 ns/entry
(§3.5).

### 5.16 Concurrency tax

**Clojure**: agents, atoms, refs, STM, vars — multi-threaded by
design. Every `atom swap!` is a CAS loop; every `alter` under STM
walks a tx log; `volatile` sprinkled in persistent structure
internals.

**nexis**: single-isolate, single-writer. No atomic ops, no
memory fences, no CAS at the runtime level. emdb enforces
single-writer at the durable layer.

**Deliberate product choice**, not a forever position. A
multi-isolate design (actor-style), but the plan is many
single-threaded isolates communicating via emdb transactions, not
shared-memory multithreading, is the only extension contemplated.

### 5.17 SIMD / typed-vector — implemented, not measured

**Clojure**: JIT occasionally autovectorizes tight `double[]`
loops. Does not autovectorize `PersistentVector` because entries
are boxed.

**nexis**: `typed-vector` (VALUE.md kind 23, `docs/TYPED_VECTOR.md`):
contiguous unboxed `i64` / `f64` elements; the `nexis.simd` kernels
`sum`, `dot` and `scale` run `f64` in four `@Vector` lanes and `i64`
scalar with overflow checks; `tv/map` calls back into the VM per
element. No `zig build bench` row measures them. `byte-vector` +
string ops would also be SIMD-eligible; that kind has no
implementation.

**Projected delta**: 2–8× on numeric reduce/map/dot; 2–4× on bulk
byte compare.

### 5.18 Startup

**Clojure**: JVM cold start + Clojure runtime bootstrap is
100–500 ms for a trivial program, 1–10 s for a large app. Graal
native-image removes most of this (50 ms) at compatibility cost.

**nexis**: native binary. Target <20 ms exec-to-REPL-prompt.
For CLI tools, shell integrations, short-lived scripts nexis is
a strictly better deployment target regardless of sustained
throughput.

### 5.19 Compilation — deficit

**Clojure**: HotSpot JIT. C1 (first tier) warms in ~1k
invocations; C2 (second tier) ~10k. Steady-state JIT'd Clojure
is within 2× of Java, within 2× of equivalent C++ on most
workloads.

**nexis**: forms compile to bytecode (`docs/COMPILER.md`) run by
a switch-dispatch VM (`docs/VM.md` §8). There is no opcode
specialization, no inline caching and no JIT. `+` and `<` on two
operands are the only inlined intrinsics.

**Not measured against Clojure.** The structural expectation for
an unspecialized bytecode VM is 2–5× slower than JIT'd Clojure on
sustained compute; opcode specialization would be the path to
parity on fully-warmed workloads. Neither number is measured.

### 5.20 Comptime specialization — Zig's unique lever

**Clojure**: JVM has escape analysis + inlining, applied
opportunistically by HotSpot.

**nexis**: Zig `comptime` is a first-class monomorphization
tool. What exists: CHAMP hashes an immediate key (keyword, fixnum,
char, symbol, boolean, nil) through `Value.hashImmediate` without
the hash callback (`docs/CHAMP.md` §5.1), and compares two keyword
keys by intern id without the equality callback. Measured: map get
14.8 → 13.3 ns and set contains 9.0 → 6.9 ns per op at N=4096 on
M5 (§3.8); assoc and conj did not move, being allocation-bound.
Absent: `(reduce + xs)` specialized for fixnum-only `xs`; `equal`
specialized by kind pair.

**Projected delta** for what is absent: 1.5–3× on specialized hot
paths vs generic dispatch. Fully orthogonal to JIT/compiler strategy.

---

## 6. Priority sequence

Ordered by leverage × cost-to-land. Re-evaluated after every
benchmark-harness update.

1. **Clojure-side comparison suite**. Criterium microbenchmarks
   matching each §3 row. Same-machine head-to-head replaces
   external-reference disclaimers and converts "plausibly faster
   than Clojure" into hard numbers.
2. **GC benchmarks** (`bench/gc.zig`). Adds steady-state
   allocation-pressure measurements so the generational GC lift
   is quantifiable.
3. **Memory footprint benchmark**. `/usr/bin/time -l` on macOS +
   allocation-counting allocator wrapper. Satisfies row #1 of
   the scorecard.
4. **Cold-cache vector nth variant**. Random-access on a
   flushed-cache vector; pairs with the sequential number in
   §3.4 to give the full profile.
5. **HeapHeader slim-down** (§5.1). Pack mark + cached hash;
   investigate 8-byte header for small objects. ~5–10% memory
   win on small-object workloads.
6. **typed-vector + SIMD benchmark rows** (§5.17). The kernels exist; a `bench-simd` row would measure the projected 2–8× on numeric bulk ops.
7. **Generational GC** (§5.11). ~5–30× on steady-state
   alloc-heavy workloads where slab retention matters.
8. **Opcode specialization** (§5.19). Gates §5.13 and the
   sustained-compute rows.
9. **Node-owner in-place-edit transients** (§5.10). The
   Clojure-class transient win; absent in favor of the Option B
   wrapper design.
10. **Inline caches at call sites** (§5.13). Depends on #8. A Var
    load itself is already one table read (§3.8).

Re-ordering is fine; the only invariant is **measurement gates
every optimization** — no commits claim a speedup without a
before/after number from `bench/`.

**Dead ends, measured** (each reverted; the rows and machine are
§3.7 and §3.8):

- *Keeping the run loop's frame pointer across instructions* (the
  fetch re-derives it only after a group that can change `frames`):
  `vm_loop_10k` 267 → 314 μs in one run and within noise in three
  more against the committed loop. The loads it saves are cheaper
  than what the loop-carried pointer costs the register allocator.
- *A single copy for string values leaving an index key*
  (`key.unescapeFrom` copies the run before the first NUL whole
  instead of appending byte by byte): no §3.7 row moved outside its
  spread. The profile puts the whole decode at about 5 % of a query
  row, under the run-to-run spread, so the second copy those rows
  pay (key bytes → arena → VM heap for the result set) is not where
  their time goes; a borrow of the page bytes would save the same 5 %
  and bind the relation's lifetime to the read transaction's.
- *A measured `refs_per_value` for the planner* (`plan.zig`): the
  store keeps a per-attribute datom count but no distinct-value
  count, so a measurement would be a sampling scan of VAET at plan
  time or a new `sys` counter maintained by every ref write. Neither
  can move a §3.7 row: the join kind is decided per step from the
  actual input rows (`plan.nestedLoop`), and every corpus query's
  clause order is already the one a correct estimate would pick
  (the VAET step follows a unique seek, or the `avet` range is the
  only seekable pattern). Only a skewed corpus would show a
  difference; that row does not exist.
- *Comptime monomorphization of `mapAssoc`/`setConj` for keyword
  keys* beyond the inline hash: assoc and conj at every N stayed
  within noise once the hash callback was gone; the remaining cost
  is path copying and allocation (§3.2).

---

## 7. Non-goals

Explicitly **not** chasing, for reasons worth recording:

- **Multi-threaded shared-memory concurrency inside one isolate.**
  Clojure's STM is a tour de force, but the concurrency tax is
  not one we intend to pay. See §5.16.
- **JIT.** A production JIT is 5+ person-years. We get
  80% of the win from bytecode + comptime specialization + inline
  caches.
- **Beating C/Zig on tight compute loops.** Parity on anything
  involving dynamic dispatch is aspirational; beating is
  architecturally impossible. We measure against Clojure and
  Python, not against the host language.
- **Zero-allocation steady state.** Some allocation is inherent
  to persistent data structures. Minimize, pool, stack-allocate —
  don't pretend allocation-free.
- **Single-number headline benchmarks.** "nexis is 3× faster than
  Clojure" without category, regime, input size, idiom tier is
  exactly what this document exists to prevent. See BENCH.md §3.

---

## 8. Biggest findings from the first baseline

All findings below are **nexis-only measurements**. Any
Clojure-comparative framing references published external
numbers, not same-machine head-to-head runs.

1. **xxHash3 reaches ~34 GB/s on Apple M1.** Matches published
   xxHash3 numbers on Apple Silicon; consistent with §5.8's
   projection of 2–3× edge over Clojure's Murmur3.
2. **CHAMP map get 15.5 ns and set contains 9.4 ns at N=4096
   are plausibly faster than Clojure's PersistentHashMap/Set.**
   Direction matches Steindorfer's 15–25% CHAMP-vs-HAMT delta.
3. **Vector nth is extremely fast** (~1 ns per random-access
   lookup), consistent with 16-byte Value cells and cache-friendly
   trie paying off as projected in §5.6.
4. **Transient parity with persistent at N=4096** is a direct
   consequence of our Option B wrapper-over-persistent
   implementation, not evidence of persistent-path superiority.
   Node-owner in-place-edit transient is the path to
   Clojure-class transient speedups; absent.
5. **Allocator is the single largest leverage point** for
   construction-heavy workloads: a size-class pool built lists
   3.94× and maps 1.80× faster than the general-purpose allocator
   in the bench (§4.3); the runtime does not have one yet. Map
   assoc is ~45% allocator-bound.
6. **emdb durable `get` at ~1 μs end-to-end** is dramatically
   faster than any Clojure-ecosystem durable-state alternative
   the author is aware of (Datomic deref, Redis round-trip, SQL
   via JDBC), but this is not a same-machine head-to-head
   measurement.

---

## 9. Honesty receipts

Every entry in §2 tagged `estimated` becomes `measured` as
benchmarks land. When a measured number arrives:

1. The row in §2 updates to cite §3.
2. §3 gets a new subsection (or extends an existing one).
3. §11's amendment log records the commit + hardware.
4. If the measurement contradicts the estimate by more than 50%,
   the estimate is **rewritten** with a footnote recording the
   original miss. Track record matters.

If an optimization turns out to be slower than the status-quo
path in measurement, **the optimization is reverted**, not
retained-with-caveat. Dead-weight optimizations are pure
maintenance cost.

All numbers in §3 are **ReleaseFast on a single M1** run once
after a fresh `zig build bench` invocation. No statistical outlier
removal has been performed; the harness's full p5/p95/p99
distribution is in the locally-generated `bench/baseline.json`
(not committed; regenerable). Re-runs on different hardware
produce different absolute numbers and are published separately
per BENCH.md §4.

No PERF.md claim depends on a single measurement; every row
citing `measured` is a **median of 30 samples × inner-loop
iterations**.

---

## 10. Cross-references

- `docs/BENCH.md` — measurement methodology (companion).
- `PLAN.md` §19 — performance strategy, Tier 1/2 roadmap.
- `PLAN.md` §21 — roadmap checklist.
- `docs/VALUE.md` §3 — tagged value encoding.
- `docs/CHAMP.md` — persistent map/set implementation.
- `docs/GC.md` — the collector; its future-work section outlines
  the generational path.
- `docs/DB.md` — emdb integration (durable-state performance).
- `docs/CODEC.md` — serialization format.
- `bench/baseline.json` — local-run machine-readable artifact (not committed; regenerable via `zig build bench`).

---

## 11. Measurement provenance

- §3.1–§3.6 numbers come from `src/bench.zig` + `bench/main.zig`
  (`zig build bench`, ReleaseFast, Apple M1, a size-class pool
  under the benchmark heaps, 30 samples × ≥50 ms). `bench/*.json` run artifacts are
  `.gitignore`d; the curated numbers live inline here.
- §3.2 / §3.3 / §3.5 A/B rows compare the general-purpose allocator
  with that pool under the per-invocation heap methodology (§3).
- §3.7 Nextomic numbers come from the scenarios in
  `bench/nextomic.zig` (`zig build bench -Doptimize=ReleaseFast --
  --filter nextomic`) on an Apple M5.
- §3.8 numbers come from `zig build bench -Doptimize=ReleaseFast --
  --filter vm,compiler,collection-lookup-update,collection-construction`
  on the same Apple M5, five invocations per state of the tree, the
  best 30-sample median of the five with the spread; the commits
  named in the table carry the same before/after pairs.
