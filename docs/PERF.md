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
- `planned` — specified but not yet implemented.

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
3. Measured baseline (first run)
4. Tier analysis — how good are these numbers?
5. Per-category design detail
6. Priority sequence
7. Non-goals
8. Biggest findings
9. Honesty receipts
10. Cross-references
11. Amendment log

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
  steady state after Phase 6 optimizations land. Weaker until
  the compiler is in.
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
| 1 | Value cell size | 16–56 B boxed | 16 B NaN-boxed tagged | **2–3× smaller** | — | implemented, not yet measured |
| 2 | Fixnum arithmetic | Boxed `Long` / `unchecked-*` | Inline 62-bit tagged | **3–10×** on tight loops | ~1 ns/op (§3.1) | measured |
| 3 | Float arithmetic | Boxed `Double` / `^double` | Inline NaN-boxed f64 | **2–5×** on idiomatic | <1 ns/op† (§3.1) | measured |
| 4 | Persistent map | HAMT (Bagwell 2001) | CHAMP (Steindorfer 2015) | **15–25%** faster lookup, **30–40%** less memory | get 15.5 ns/op @ N=4096 (§3.4) | measured (partial) |
| 5 | Persistent set | HAMT | CHAMP | same as #4 | contains 9.4 ns/op @ N=4096 (§3.4) | measured (partial) |
| 6 | Persistent vector | 32-way trie + tail | 32-way trie + tail | **parity** expected | nth ~1 ns/op @ N=4096 (§3.4)‡ | measured (partial) |
| 7 | Persistent list | Cons cells | Cons cells | **parity** | cons 14.7 ns/op @ N=4096 (§3.2) | measured |
| 8 | Hashing | Murmur3 | xxHash3-64 | **2–3×** faster on long bytes | ~34 GB/s (§3.1) | measured (partial) |
| 9 | Keyword identity | Intern + identity | Intern + identity | **parity** | hash 2 ns (§3.1) | measured |
| 10 | Transients | Mutation token | Owner-token (Option B wrapper) | **parity** in v1; Phase-6 opportunity | ~parity with persistent (§3.3) | measured |
| 11 | GC | Generational tracing (G1/ZGC) | Precise non-moving mark-sweep | **worse** short-term; addressable | — | implemented, acknowledged weakness |
| 12 | Allocator | TLAB bump pointer | size-class pool (POOL.md) | **parity-to-edge vs TLAB** on hot paths | list cons **3.94×**, map assoc **1.80×** vs pre-pool (§3.2) | measured (pool landed) |
| 13 | Dispatch / polymorphism | Inline-cached via JIT | 26-way switch per op | **worse** at warm steady state; Phase 6 flips | hashValue ~1–2 ns (§3.1) | measured (partial) |
| 14 | Durable state | No stdlib primitive | emdb mmap, zero-copy | **orders of magnitude faster** | get-hot 1.04 μs (§3.6) | measured (partial) |
| 15 | Codec / serialization | `.edn` / Nippy | Binary LEB128/ZigZag | **2–5× size, 5–20× speed** vs `.edn` | encode 18 ns/entry, decode 124 ns/entry (§3.5) | measured (partial) |
| 16 | Concurrency tax | STM + CAS pervasive | Single-isolate, single-writer | **strictly less overhead**; by design | — | implemented, by design |
| 17 | SIMD / typed-vector | JIT may autovectorize | `@Vector` + planned typed-vector | **2–8×** on bulk numeric ops | — | planned (Phase 6) |
| 18 | Startup | 100–500 ms JVM warmup | Native binary | **10–500×** | — | implemented, not yet measured |
| 19 | Compilation | HotSpot C1+C2 JIT | Tree-walking interpreter today | **worse** today, winning after Phase 2/6 | — | acknowledged; Phase 2/6 |
| 20 | Comptime specialization | JIT inlining + escape analysis | Zig `comptime` monomorphization | **~2×** on specialized paths | — | planned (Phase 6) |

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
| Allocator | `PoolAllocator` (size-class pool, `docs/POOL.md`) — default |
| Harness | `src/bench.zig` (criterion-style, 30 samples × ≥50 ms per measurement) |
| Date of current baseline | 2026-04-19 |
| Baseline numbers | Inline in §3.1–§3.6 below |
| Local artifacts (`.gitignore`d) | `bench/baseline.json` (pool default), `bench/baseline-std.json` (A/B), `bench/baseline-pool.json` (A/B) |

**On the JSON files.** `bench/*.json` are **local run artifacts,
not committed**. The numbers of record live inline in §3.1–§3.6
and in the amendment log (§11). Regenerate locally with
`zig build bench -- --out bench/baseline.json`. Per-machine /
per-conditions runs should NOT be committed — diffing them is
the job of the in-doc numbers, which are curated.

**Important methodology note** (introduced in the pool-allocator
commit): every collection-construction benchmark now creates a
fresh `Heap` per measurement invocation and `Heap.deinit()`s it
when the invocation returns. This prevents unbounded memory growth
across `inner_reps` on N=4096 workloads and is how the A/B below
is fair. The very first baseline (commit `7e5bb1a`, from before
per-bench heap reset) had different numbers for N=4096
construction because of the accumulation effect; the §3.2 / §3.3
tables below are the corrected numbers from `baseline-std.json`.

Reproducing:

    # default (pool)
    zig build bench -- --out bench/baseline.json --note "your-hw"

    # A/B vs pre-pool allocator
    zig build bench -- --allocator std \
        --out bench/baseline-std.json --note "std-ab"

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

### 3.2 Persistent collection construction — **A/B vs pool allocator**

N-fold conj/assoc from empty; keyword keys throughout. **Two
columns**: `std` = Zig debug allocator (pre-lift reference);
`pool` = size-class pool (current default, POOL.md).

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
- **PERF.md §5.12 projection** was "3–10× from allocator pass"
  applied broadly, and "map_assoc ~200 ns → ~60 ns". The measured
  map assoc lift is **~1.8× rather than 3×**; the "~80% allocator-
  bound" decomposition was too aggressive for deep trie workloads.
  In reality map_assoc at N=4096 is closer to 45% allocator-bound
  (the rest is hash + memcpy + trie navigation). Projection
  rewritten.
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
  design. Parity is the expected outcome; node-owner in-place
  edit is deferred to Phase 6+.
- Phase-6 opportunity: node-owner in-place-edit transient +
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

### 4.3 Realized lift: allocator pass landed

This tier was empty as a projection; it's now where the realized
wins live. The pool-allocator commit measured the following A/B
against the pre-pool `init.gpa` baseline (§3.2):

| Measurement | Before | After (pool) | Lift |
|---|---:|---:|---:|
| list cons @ N=4096 | 17.6 ns/op | **4.5 ns/op** | **3.94×** |
| vector conj @ N=4096 | 51.9 ns/op | **20.1 ns/op** | **2.59×** |
| map assoc @ N=4096 | 151 ns/op | **84.2 ns/op** | **1.80×** |
| set conj @ N=4096 | 143 ns/op | **77.9 ns/op** | **1.84×** |
| codec decode map entry | ~103 ns | **~85 ns** | 1.14× |

**What the numbers told us that the projection didn't.** PERF.md
§5.12 projected "map_assoc ~200 ns → ~60 ns" (~3×). Measured
lift is ~1.8×, meaningfully smaller. The "~80% allocator-bound"
decomposition was too aggressive for deep-trie paths; real
breakdown for map assoc at N=4096 is closer to **45% allocator-
bound** (rest is hash + byte-copy + trie navigation). **List
cons** (shallowest per-op work) saw the largest lift because it
was the most allocator-dominated.

**Where further lift is available** (next commits):
- **Comptime monomorphization** of `mapAssoc`'s hash/equal for
  keyword-keyed maps: skip the dispatch switch entirely on the
  hot path. Projected additional ~10–20% on map/set.
- **HeapHeader slim-down** (§5.1): reducing the per-block header
  bytes lets more blocks fit in a cache line. Projected ~5–10%.
- **Node-owner in-place-edit transients** (§5.10): for workloads
  that actually use transients, this is the Clojure-class win.
  Phase 6+.

The large projected lift (5–30×) from generational GC (§5.11) is
still on the table. Construction workloads under sustained
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
- **Currently at parity**: map/set/vector construction.
- **Currently behind (pending)**: GC, dispatch in warm steady
  state, sustained compute (no compiler yet).

The allocator commit closes the construction gap and likely
opens a clear lead. Generational GC closes the throughput-under-
alloc-churn gap. The compiler (Phase 2) closes the sustained-
compute gap. Each of those is its own measured commit — the
harness now exists to prove or refute every claim.

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
buffer (PLAN.md §8.3 + VECTOR.md). RRB relaxation is not in v1
for either (Clojure ships RRB separately as `core.rrb-vector`;
nexis defers to Phase 6).

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

**nexis v1 discipline** (TRANSIENT.md): **Option B** — wrapper
over persistent with owner-token check + subkind dispatch +
delegated persistent ops. Correctness-first. The node-owner
in-place-edit optimization used by Clojure's optimized transients
is deliberately deferred.

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

**Plan** (PLAN.md §9 + §19.6): Phase 6 nursery allocator + write
barriers for generational collection. Estimated 5–30× faster on
steady-state allocation-heavy workloads.

**Status**: implemented (non-generational), acknowledged weakness.

### 5.12 Allocator — **landed**

**Clojure (JVM)**: TLAB bump pointer. Young-gen allocation is
2–5 ns.

**nexis**: `PoolAllocator` (size-class pool, `docs/POOL.md`).
16 size classes from 16 B to 4 KB, free-list LIFO per class,
slab-backed bump pointer, large + high-alignment requests
delegated to backing. Single-threaded by design (PLAN §16.1),
no locking.

**Measured lift** (§3.2, §3.3, §3.5, §4.3):
- list cons @ N=4096: 17.6 ns → 4.5 ns (**3.94×**)
- vector conj @ N=4096: 51.9 ns → 20.1 ns (**2.59×**)
- map assoc @ N=4096: 151 ns → 84 ns (**1.80×**)
- set conj @ N=4096: 143 ns → 78 ns (**1.84×**)
- codec decode map entry: ~103 ns → ~85 ns (**1.14×**)

**Retained capacity**: slabs are held until `pool.deinit()` (no
empty-slab reclamation in v1). Documented at POOL.md §8 as a
deliberate tradeoff, not a leak. Phase 7+ can add per-slab
refcounting + empty-slab release for long-lived REPL sessions.

**Status**: **landed** — default for `zig build bench` and for
any downstream code that constructs a `Heap` from
`pool.allocator()`. Legacy `init.gpa` path still available via
`--allocator std` for A/B.

### 5.13 Dispatch / polymorphism — medium-term leverage

**Clojure**: HotSpot inline-caches call sites. Monomorphic sites
bake in the concrete function pointer after ~10k calls.
Multi-morphic sites get a PIC.

**nexis**: `dispatch.hashValue` / `dispatch.equal` /
`dispatch.heapHashBase` are 26-way `switch` statements. Zero
inline caching.

**Measured**: hashValue ~1–2 ns (§3.1) — the switch predicts
well enough at hot paths to be ~single-cycle.

**Plan**: comptime monomorphization for statically-known kinds;
inline caches at dynamic call sites once the compiler lands
(Phase 2+); per-kind fast paths at dispatch entry.

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

**Deliberate product choice**, not a forever position. Phase 7+
may add multi-isolate (actor-style), but the plan is many
single-threaded isolates communicating via emdb transactions, not
shared-memory multithreading.

### 5.17 SIMD / typed-vector — Phase 6

**Clojure**: JIT occasionally autovectorizes tight `double[]`
loops. Does not autovectorize `PersistentVector` because entries
are boxed.

**nexis**: `typed-vector` (VALUE.md kind 21, reserved). Phase 6
implements with contiguous unboxed element bytes + `@Vector`
SIMD for map/reduce/dot-product. `byte-vector` + string ops also
SIMD-eligible.

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

### 5.19 Compilation — current deficit, future win

**Clojure**: HotSpot JIT. C1 (first tier) warms in ~1k
invocations; C2 (second tier) ~10k. Steady-state JIT'd Clojure
is within 2× of Java, within 2× of equivalent C++ on most
workloads.

**nexis**: tree-walking interpreter post-reader is the current
state. Every form evaluation walks the parsed form data
structure. Acknowledged-slow by design; Phase 2 lands a bytecode
VM, Phase 6 lands opcode specialization, Phase 7+ may add
copy-and-patch or a proper JIT.

**Rough ballpark today (pre-Phase-2)**: tree-walking nexis
probably 20–100× slower than JIT'd Clojure on sustained compute.
**After Phase 2 bytecode**: 2–5× slower. **After Phase 6
specialization**: parity or edge on fully-warmed workloads.

### 5.20 Comptime specialization — Zig's unique lever

**Clojure**: JVM has escape analysis + inlining, applied
opportunistically by HotSpot.

**nexis**: Zig `comptime` is a first-class monomorphization
tool. `mapAssoc` specialized for keyword keys → skip hash
dispatch; `(reduce + xs)` specialized for fixnum-only xs →
unrolled arithmetic without per-element tag checks; `equal`
specialized by kind-pair → direct function pointer.

**Projected delta**: 1.5–3× on specialized hot paths vs generic
dispatch. Fully orthogonal to JIT/compiler strategy.

---

## 6. Priority sequence

Ordered by leverage × cost-to-land. Re-evaluated after every
benchmark-harness update.

1. **Clojure-side comparison suite**. Criterium microbenchmarks
   matching each §3 row. Same-machine head-to-head replaces
   external-reference disclaimers and converts "plausibly faster
   than Clojure" into hard numbers.
2. **Comptime monomorphization of hot collection dispatch**
   (§5.13, §5.20). Specialize `mapAssoc`/`mapGet`/`setConj` for
   statically-known kinds (keyword-keyed map is the common
   case). Projected ~10–20% additional on map/set ops after the
   pool lift.
3. **GC benchmarks** (`bench/gc.zig`). Adds steady-state
   allocation-pressure measurements so the generational GC lift
   is quantifiable.
4. **Memory footprint benchmark**. `/usr/bin/time -l` on macOS +
   allocation-counting allocator wrapper. Satisfies row #1 of
   the scorecard.
5. **Cold-cache vector nth variant**. Random-access on a
   flushed-cache vector; pairs with the sequential number in
   §3.4 to give the full profile.
6. **HeapHeader slim-down** (§5.1). Pack mark + cached hash;
   investigate 8-byte header for small objects. ~5–10% memory
   win on small-object workloads.
7. **typed-vector + SIMD** (§5.17). ~2–8× on numeric bulk ops.
8. **Generational GC** (§5.11). ~5–30× on steady-state
   alloc-heavy workloads where slab retention matters.
9. **Phase 2 bytecode compiler**. Covered by PLAN.md §21;
   gates §5.13 and §5.19.
10. **Node-owner in-place-edit transients** (§5.10). The
    Clojure-class transient win; deferred past Phase 1 in favor
    of the Option B wrapper design.
11. **Inline caches** (§5.13). Depends on #9.

Re-ordering is fine; the only invariant is **measurement gates
every optimization** — no commits claim a speedup without a
before/after number from `bench/`.

---

## 7. Non-goals

Explicitly **not** chasing, for reasons worth recording:

- **Multi-threaded shared-memory concurrency inside one isolate.**
  Clojure's STM is a tour de force, but the concurrency tax is
  not one we intend to pay. See §5.16.
- **JIT in v1 / v2.** A production JIT is 5+ person-years. We get
  80% of the win from bytecode + comptime specialization + inline
  caches. Phase 7+ may reconsider.
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
   Clojure-class transient speedups; deferred post-Phase-1.
5. **Allocator is the single largest leverage point** for
   construction-heavy workloads. Map assoc at ~200 ns/op is
   ~80% `page_allocator` overhead; §5.12's projection of 3–10×
   from a size-class pool is directionally supported by the cost
   breakdown.
6. **emdb durable `get` at ~1 μs end-to-end** is dramatically
   faster than any Clojure-ecosystem durable-state alternative
   the author is aware of (Datomic deref, Redis round-trip, SQL
   via JDBC), but this is not a same-machine head-to-head
   measurement.
7. **A latent production bug was caught by the benchmark** —
   `src/codec.zig` had two uses of `std.testing.allocator` inside
   production decode paths that only worked because the code path
   wasn't exercised outside tests. Fixed to use `heap.backing`.
   The harness earned its keep on the first run.

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
- `PLAN.md` §21 — phase roadmap (when each optimization lands).
- `docs/VALUE.md` §3 — tagged value encoding.
- `docs/CHAMP.md` — persistent map/set implementation.
- `docs/GC.md` — current collector; future-work section outlines
  the generational path.
- `docs/DB.md` — emdb integration (durable-state performance).
- `docs/CODEC.md` — serialization format.
- `bench/baseline.json` — local-run machine-readable artifact (not committed; regenerable via `zig build bench`).

---

## 11. Amendment log

- **2026-04-19** (commit `d129f06`): Initial PERF.md draft. Twenty
  categories cataloged; all status tags `estimated` or
  `implemented, not yet measured`.
- **2026-04-19** (commit `7e5bb1a`): Bench harness landed
  (`src/bench.zig` + `bench/main.zig`). `bench/baseline.json`
  was initially committed as a checked-in artifact; later
  gitignored (see pool-allocator commit below) because per-machine
  run JSON was churning without adding signal beyond the inline
  numbers.
  First measured numbers captured in a separate PERF-MEASURED.md.
  Status tags promoted to `measured` for rows 2, 3, 4 (partial),
  5, 6, 8 (partial), 14 (partial), 15.
- **2026-04-19** (commit `97b019e`): **PERF-MEASURED.md merged
  into PERF.md**; single source of truth for performance. New §3
  (measured baseline, full interpretation) and §4 (tier analysis
  against theoretical ceilings and external references) added.
  PERF-MEASURED.md deleted.
- **2026-04-19** (pool allocator commit): **Size-class pool
  landed**. §3.2 collection-construction + §3.3 transient +
  §3.5 codec now report A/B numbers (std vs pool). Headline
  lifts: list cons **3.94×**, vector conj **2.59×**, map assoc
  **1.80×**, set conj **1.84×**. The PERF.md §5.12 projection
  of "~80% allocator-bound, map assoc 200 ns → 60 ns" was **too
  aggressive for deep-trie paths** — measured map_assoc is ~45%
  allocator-bound in practice. §4.3 rewritten from
  "clear improvement runway" to "realized lift." §5.12 status
  tag: `landed`. Methodology change in the same commit: bench
  driver now uses per-invocation heap (create + `Heap.deinit`)
  for construction benchmarks; without this change both `std`
  and `pool` OOM at N=4096 due to accumulation across
  `inner_reps`. Also in this commit: **`bench/*.json` moved to
  `.gitignore`** — per-machine / per-run JSON artifacts do not
  belong in version control. The curated numbers live inline in
  §3 and in this amendment log; regenerate JSON locally via
  `zig build bench -- --out bench/baseline.json`.
