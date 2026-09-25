## BENCH.md — Benchmark method, reporting rules and the harness

How nexis measures itself and what a published performance claim must
satisfy. §1–§8 and §11 are the frozen contract for any comparison,
especially with Clojure; §10 describes the harness, `zig build bench`.
The numbers of record live in `docs/PERF.md` §3, once each, with their
provenance in its §11.

Two rules come first. A performance claim rests only on measured
numbers taken under this document, from ReleaseFast builds; a Debug
build is never a measurement. No comparative benchmark is published
before real same-machine numbers exist on both sides, and when one is,
the cases where Clojure wins are published with it (§8).

---

### 1. Four standards

Every published claim is:

1. **Numerical**: measured, with units, not asserted.
2. **Accurate**: repeated runs with the statistics of §3, the host of
   §4, and instructions that let a third party rerun it within noise.
3. **Fair**: idiomatic code on each side, stock tooling and
   configuration (§5, §6); a competent practitioner of the other
   language would call the source a reasonable way to write it.
4. **Relevant**: it measures a user workload or a specific
   architectural claim.

A benchmark that fails one standard is withdrawn, not reframed.

---

### 2. Categories

Every measurement carries exactly one category, and a claim names its
category, regime (cold, warm, steady state), input size and idiom
tier.

| Category | Measures | Tool |
|---|---|---|
| Startup | process start to first result | `hyperfine` |
| Short-lived script | wall time of a small program run once | `hyperfine` |
| Warm microbenchmark | per-operation cost on warmed code | the harness (§10); `criterium` for Clojure |
| Steady-state throughput | operations per second on a long warmed workload | the harness; `criterium` |
| Collection construction | building an N-element collection; persistent and transient paths separately | the harness |
| Collection lookup/update | `get`, `assoc`, `conj`, `nth` across sizes | the harness |
| Memory footprint | peak RSS or allocated bytes for a fixed workload | `/usr/bin/time -l` (macOS), GNU `time -v` |
| Database-integrated | workloads through emdb, durable refs or Nextomic | the harness, `hyperfine` |
| Macrobenchmark | a realistic program end to end | `hyperfine` |

---

### 3. Statistics

- The **median** is the headline, never the mean: collector pauses and
  page faults skew means.
- **p5, p95 and p99** accompany it, so tails show.
- **At least 30 samples** for warm microbenchmarks; at least 10 for
  startup and macro workloads. Clojure microbenchmarks use
  `criterium`'s own sampling.
- **A ratio never appears without the absolute numbers** beneath it.
- **No means across heterogeneous benchmarks** (no geomean tables).
- A full report shows distributions (box or violin plots), not bars
  without error.
- A result whose run-to-run variance exceeds 20 % is investigated and
  rerun, or withdrawn.

---

### 4. Host

Every result records the exact CPU, RAM, OS and version, Zig version,
optimize mode, whether the machine was idle, and the frequency-scaling
setting where the OS exposes it. Results from different machines are
not comparable: a report runs on one machine, and a rerun elsewhere is
published separately with its own host. `docs/PERF.md` §11 records the
host of every number of record.

---

### 5. Clojure-side fairness

- `criterium` for every microbenchmark; `*warn-on-reflection*` on,
  with every warning resolved.
- Arithmetic in three tiers, each labelled: idiomatic boxed,
  `^long`/`^double` hinted, and `unchecked-*` with
  `*unchecked-math*`. nexis fixnums against boxed Clojure alone is not
  a claim about Clojure arithmetic.
- Transients where the community uses them (`into`, `persistent!`
  over `conj!`); pure persistent loops as their own labelled tier.
- A pinned Clojure 1.12.x on the current JDK LTS with stock flags;
  tuned-JVM or Graal native-image runs are separate, labelled rows.

---

### 6. nexis-side fairness

- The baseline is the VM as users run it: no disabled safety checks,
  and any optimization-tier variant is its own labelled row.
- Code compared with another system is idiomatic nexis (`defn`,
  `reduce`, `->>`). The harness rows of §10 call runtime primitives
  directly; they are nexis-only measurements and are never set against
  another system's idiomatic code.
- A report states that nexis runs a bytecode VM with no opcode
  specialization and no JIT, so an advantage is read as architecture
  (value layout, CHAMP, xxHash3, in-process storage), not execution
  strategy.

---

### 7. Reproducibility

A published comparison ships the source of both sides with its exact
command lines and seeded input generation, the raw per-run data (the
harness's JSON, §10), the nexis commit, the Clojure and JDK versions
and the host, and one script that reruns the suite from a clean
checkout. A result that script does not reproduce within p5–p95 on
the documented host is corrected or withdrawn.

---

### 8. Honesty

Where Clojure wins, the result is published. Each category of a report
shows at least one case where Clojure leads if one exists, or says
plainly that none was found. Mixed results show both sides, and p99
appears beside the median for both. A report that claims to win
everywhere is not published.

---

### 10. The harness: `zig build bench`

`src/bench.zig` is the harness: `Runner` (the adaptive inner loop,
warm-up and sampling), `Stats` (the order statistics), `writeTable`
and `writeJson`. `bench/main.zig` is the suite and its driver;
`bench/nextomic.zig` holds the Nextomic rows. The step builds
`bin/nexis-bench` and runs it with the arguments after `--`. The
runner and the runtime it drives are compiled ReleaseFast when
`-Doptimize` is left at Debug; an explicit `-Doptimize=ReleaseSafe`,
`ReleaseSmall` or `ReleaseFast` is used as given.

```bash
zig build bench                                  # every category, table to stdout
zig build bench -- --filter vm,codec             # named categories only, comma-separated
zig build bench -- --out run.json --note "idle"  # also the JSON report, with a note
```

An unknown flag or category prints the usage (or the list of
categories) and exits 2. JSON is written only with `--out`; run files
are artifacts and are not committed.

`zig build test` analyzes the suite against the Debug runtime, with no
code generation and no run, so an API change that breaks it fails the
gate.

| Category | §2 category | Rows |
|---|---|---|
| `scalar` | Warm microbenchmark | `fixnum_add`, `float_add`, `hash_fixnum`, `hash_keyword`, `hash_string_43b`, `xxhash3_raw_172b` |
| `collection-construction` | Collection construction | `list_cons_n`, `vector_conj_n`, `map_assoc_n`, `set_conj_n` at N = 16, 256, 4096, each invocation on a fresh heap |
| `transient-construction` | Collection construction | `transient_vector_conjbang_n`, `transient_map_assocbang_n`, `transient_set_conjbang_n` at the same N |
| `collection-lookup-update` | Collection lookup/update | `vector_nth_n_sequential`, `map_get_n_hit`, `set_contains_n_hit` at N = 256, 4096 |
| `compiler` | Warm microbenchmark | `compile_simple` (read, expand, compile `(+ 1 2)`); `eval_simple_loop`, `closure_create`, `eval_arith` (VM construction, compile and run per sample) |
| `vm` | Warm microbenchmark | `vm_loop_10k`, `vm_global_call_10k`, `vm_keyword_get_10k`: a routine compiled once, rerun on one VM |
| `codec` | Warm microbenchmark | `codec_encode_fixnum`, `codec_decode_fixnum`, `codec_encode_map_n64`, `codec_decode_map_n64` |
| `db-integrated` | Database-integrated | `db_put_commit_scalar`, `db_get_hit_scalar` on a fresh store under `$TMPDIR` |
| `nextomic` | Database-integrated | six `q_*` rows over a 200k-datom store and three `pull_*` rows over 20k entities (`docs/PERF.md` §3.7) |

**Method.** A pilot doubles its repetitions until one timing spans a
millisecond, then sets `inner_reps` so one sample lasts at least 50 ms
(one repetition when the body alone does). Ten warm-up samples are
discarded and 30 kept. A sample is the elapsed `CLOCK_MONOTONIC` time
over `inner_reps`, kept as a fraction of a nanosecond. Setup stays
outside the timed body unless the row measures it (the `compiler`
pipeline rows), and a body that allocates keeps memory bounded: the
construction rows free their heap per invocation, the decode rows drop
their scratch heap every 16 MiB. The heaps sit on the process
allocator, as the runtime's do.

**Output.** The table has one line per row: benchmark, category,
parameter (N, or `-`), median, p5, p95 and ops/sec from the median.
The JSON (`schema_version` 1) carries `generated_at_unix`, a `host`
object (`cpu` from the build target, `os`, `ram` left empty,
`zig_version`, `optimize_mode`, `note`) and one `results` entry per
row with `name`, `category`, `param`, `samples`, `inner_reps`,
`warmup_iters`, `min_ns`, `p5_ns`, `median_ns`, `p95_ns`, `p99_ns`,
`max_ns`, `mean_ns`, `stddev_ns` and `ops_per_sec_median`. Percentiles
are nearest-rank, never interpolated. `src/bench.zig`'s inline tests
cover the statistics, a trivial run and JSON escaping.

---

### 11. The test for a report

Every comparative report must be introducible with, and survive, this
sentence:

> "We measured several clearly defined performance regimes, with
> published source and methodology, and here is where nexis is
> faster, where it is comparable, and where Clojure wins."

A result that cannot be defended under it does not ship.
