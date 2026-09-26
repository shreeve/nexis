## BENCH.md — Benchmark method, reporting rules and the harness

How nexis measures itself and what a published performance claim must
satisfy. §1–§8 and §11 are the frozen contract for any comparison,
especially with Clojure; §10 describes the harness, `zig build bench`;
§12 the comparison with babashka and Datalevin, `bench/compare/`.
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
| `nextomic` | Database-integrated | six `q_*` rows over a 200k-datom store and three `pull_*` rows over 20k entities (`docs/PERF.md` §3.7); each row runs once and must return the rows the corpus implies before it is timed |

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

---

### 12. Comparisons: babashka and Datalevin

`bench/compare/` sets nexis beside the two systems that share its
shape: one native binary that starts at once and runs Clojure-dialect
programs without a JVM start. **babashka** (`bb`) runs Clojure through
SCI, an interpreter, inside a GraalVM native image. **Datalevin**'s
`dtlv` is a native image of the Datalevin database (DLMDB, an LMDB
fork, under a Datalog layer); `dtlv exec` interprets the glue code
with SCI and calls the database natively. Neither is Clojure on
HotSpot: §5's JVM comparison, with `criterium` and the three
arithmetic tiers, does not exist yet, and nothing here speaks for it.
The results of record are `docs/PERF.md` §3.11.

**What runs.** Language workloads, nexis against babashka: process
start to first output (`-e '(+ 1 2)'`), naive `fib` 30, a 1M-iteration
`loop`/`recur`, a 1M-entry int-keyed hash map built by `assoc` and
read back (and the same through a transient), 1M `conj` onto a vector
and 1M `nth`, a 1.08 MB string built with `join` and `split` back,
`sort` of 1M ints, `frequencies` and `group-by` over 1M ints, 1M calls
destructuring a map and a vector, and `filter`/`map`/`reduce` over 1M
small maps. Database workloads, Nextomic against Datalevin, over 100
departments and 100,000 people with five attributes each (email,
unique; name; age; department, a ref; salary):

| Phase | Work |
|---|---|
| `create` | create the store, install the schema, transact the departments |
| `load` | 100 transactions of 1,000 people each, map forms |
| `open` | reopen the loaded store in a new process |
| `lookup-10k` | 10,000 entities by lookup ref on the unique email, one attribute read each |
| `join3-20x` | a three-clause join (department name → people → names), once for each of 20 departments, 20,000 rows |
| `aggregate` | `(sum ?s)` of salaries per department `:with` the person, over every person |
| `pull-10k` | `pull-many` of 10,000 people with a nested ref pattern |
| `tx-1k-durable` | 1,000 transactions of one datom each, in each system's default commit |
| `tx-1k-nosync` | the same with the commit's flush off and one sync at the end |
| `as-of+history` | nexis only: the salary total as of the basis before the writes, and a `history` count |
| `create-nosync`, `load-nosync` | `create` and `load` with the flush off and one sync at the end |

Datalevin has no time views: `datalevin.core`'s public vars (listed
by `(ns-publics 'datalevin.core)` under `dtlv exec`) hold no `as-of`,
`since` or `history`, so that row is nexis alone and says so. The
store's size after `load` is read with `du` (allocated blocks) and as
the sum of file lengths.

**The same code.** A language workload is one body,
`bench/compare/lang/NAME.clj`, run by both after a prelude
(`prelude.nx`, `prelude.bb.clj`) that differs only in the clock, the
string namespace, and `split`'s separator: nexis has no regex (PLAN
§24 #9), so it splits on a string where babashka splits on `#","`. The
database workloads are twin scripts, `db/nexis-*.nx` and
`db/dtlv-*.clj`, the same data from the same arithmetic, the same
batches and the same queries, differing only in API spelling.
Inputs are generated, not random, and the runner fails a workload
unless every run of every implementation prints the same answer for
every phase, so every row is equal work.

**Method.** `bb bench/compare/run.clj --out DIR [--n 10]` builds
`bin/nexis` ReleaseFast and records the host (CPU, cores, RAM, OS),
the versions (nexis commit and whether `src/` is dirty, Zig, `bb`,
`dtlv`), the date and the load average before and after. Each
workload runs once per implementation, discarded, to warm the file
cache; then `--n` rounds (at least 10; startup 3 × `--n`), the
implementations alternating and their order rotated each round. Every
run is a fresh process under `/usr/bin/time -l`. A phase's time is
read inside the process with the implementation's monotonic clock
(`nano-time`, `System/nanoTime`, SCI's `system-time`) around the work
alone, input generation outside it, and each cell reports the median
with the minimum and the nearest-rank p95. Beside it the runner
records each process's wall time (spawn to exit, through the `time`
wrapper) and peak RSS (`maximum resident set size`). A database run
creates fresh stores, and the query phases run in a second process
against the store the first built. The runner waits for the 1-minute
load average to fall under `--max-load` (4) before a workload, and a
workload during which it rose above that is discarded and repeated,
up to three attempts, all kept in the JSON. `DIR/results.md` is the
table, `DIR/results.json` every run, and `DIR/src/` the exact
programs.

**What is not comparable, and why a row may mislead.**

- *Execution.* nexis compiles to bytecode and interprets it (§6).
  babashka's SCI interprets the program too, but the Clojure library
  it calls (`sort`, `frequencies`, `group-by`, `clojure.string`,
  `reduce`, the persistent collections) is compiled ahead of time into
  the native image. Where a workload's time is inside library
  functions, the row compares nexis's library, some of it written in
  nexis and interpreted (`frequencies`, `group-by`), with compiled
  Java. Datalevin's engine is compiled Java and C; Nextomic's is Zig;
  both run their glue through an interpreter.
- *Sequences.* nexis sequences are eager (PLAN §23 #14): `map` and
  `filter` build their whole result, where babashka's are lazy and
  chunked. The pipeline row runs the same code and pays for that.
- *Transients.* nexis's transients are wrappers over the persistent
  operations (`docs/TRANSIENT.md`), not in-place node edits.
- *Durability.* A default Nextomic commit (`:commit`, `docs/DB.md`
  §3.3) syncs nothing: it is atomic and survives a crash of the
  process, and the file is synced once when the connection is
  released, outside the timed phase. With `{:durability :durable}`
  a commit is two `fcntl(F_FULLFSYNC)` calls (data, then meta; emdb's
  `datasync` on macOS), which ask the drive to empty its write cache.
  Datalevin 1.1.0's datalog store opens with the LMDB flags
  `#{:nordahead :notls}` (`get-env-flags`) and its write-ahead log off
  (`opts` gives `:wal? false`), so a commit syncs as LMDB does. Its
  measured cost per commit (`docs/PERF.md` §3.11) is a twentieth of one
  `F_FULLFSYNC` on the same drive, consistent with `fsync(2)`, which on
  macOS returns before the drive's cache is flushed; the system calls
  themselves were not traced (that needs root). The `tx-1k-durable`
  and `load` rows therefore compare different guarantees, each
  system's default. The `nosync` rows compare the
  transaction machinery alone: Nextomic's `{:sync :none}` per
  transaction and `d/sync` at the end; Datalevin's `:nosync`
  environment flag and `sync` at the end.
- *What a write stores.* Nextomic writes every datom to EAVT and AEVT,
  AVET for unique and indexed attributes, VAET for refs, the four
  history twins of those, and a txlog entry per transaction
  (`docs/NEXTOMIC.md` §2). Datalevin writes EAV and AVE (every
  attribute is in AVE; `datoms :ave` answers for an unindexed one) and
  keeps no history. Load time and store size pay for history on the
  nexis side. The nexis schema marks `:person/age` indexed, which
  Datalevin does without being asked.
- *Caches.* Nextomic caches a query's parse per VM; Datalevin keeps
  caches of its own (`opts` shows `:cache-limit 512`). Every timed
  query in a run has inputs of its own, so no result can come from a
  result cache.
- *Memory.* Peak RSS reflects each collector's policy (nexis's
  non-moving mark-sweep over the process allocator; the native
  image's collector and its heap sizing) as much as live data.
- *Startup* includes the `time` wrapper's spawn, the same for both.
