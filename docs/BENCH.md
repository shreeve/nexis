## BENCH.md — Benchmark method, reporting rules and the harness

How nexis measures itself and what a published performance claim must
satisfy. §1–§8 and §11 are the frozen contract for any comparison,
especially with Clojure; §10 describes the harness, `zig build bench`;
§12 the comparison with babashka, JVM Clojure, Datalevin and Datomic,
`bench/compare/`.
The numbers of record live in `docs/PERF.md` §3, once each, with their
provenance in its §11.

Two rules come first. A performance claim rests only on measured
numbers taken under this document, from builds optimized for speed
(`-Doptimize=fast`); a Debug
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
runner and the runtime it drives are compiled `fast` when
`-Doptimize` is left at `debug`; an explicit `-Doptimize=safe`,
`small` or `fast` is used as given.

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

### 12. Comparisons: babashka, JVM Clojure, Datalevin and Datomic

`bench/compare/` sets nexis beside four systems. Two share its shape,
one native binary that starts at once and runs Clojure-dialect
programs without a JVM start: **babashka** (`bb`) runs Clojure through
SCI, an interpreter, inside a GraalVM native image, and **Datalevin**'s
`dtlv` is a native image of the Datalevin database (DLMDB, an LMDB
fork, under a Datalog layer); `dtlv exec` interprets the glue code
with SCI and calls the database natively. Two are the reference
implementations on HotSpot: **Clojure** 1.12 run by the Clojure CLI
(`clojure -M`), and **Datomic**, both as **Datomic Local**
(`com.datomic/local`, the client API in the program's own process over
files in a directory) and as **Datomic Pro** (a peer in the program's
process, a dev transactor as a second process on the same host, its
storage H2). The Clojure column runs the same idiomatic programs as
the others, cold and warmed in one process; it is not §5's
`criterium` comparison with its three arithmetic tiers, which is not
measured, and nothing here speaks for it. The results of record are
`docs/PERF.md` §3.11 (macOS: babashka and Datalevin) and §3.15
(Linux: all five).

**What runs.** Language workloads, nexis against babashka and Clojure:
process start to first output (`-e '(+ 1 2)'`), naive `fib` 30, a
1M-iteration `loop`/`recur`, a 1M-entry int-keyed hash map built by
`assoc` and read back (and the same through a transient), 1M `conj`
onto a vector and 1M `nth`, a 1.08 MB string built with `join` and
`split` back, `sort` of 1M ints, `frequencies` and `group-by` over 1M
ints, 1M calls destructuring a map and a vector, and
`filter`/`map`/`reduce` over 1M small maps. Database workloads,
Nextomic against Datalevin, Datomic Local and Datomic Pro, over 100
departments and 100,000 people with five attributes each (email,
unique; name; age; department, a ref; salary):

| Phase | Work |
|---|---|
| `create` | create the store, install the schema, transact the departments |
| `load` | 100 transactions of 1,000 people each, map forms, in the default commit |
| `index` | Datomic Pro only: `request-index` and `sync-index` after the load, so the store's size and the queries see indexed data |
| `open` | reopen the loaded store in a new process (Datomic Pro: a new peer connects) |
| `lookup-10k` | 10,000 entities by lookup ref on the unique email, one attribute read each |
| `join3-20x` | a three-clause join (department name → people → names), once for each of 20 departments, 20,000 rows |
| `aggregate` | `(sum ?s)` of salaries per department `:with` the person, over every person |
| `pull-10k` | a pull of 10,000 people with a nested ref pattern |
| `lookup-10k-warm`, `pull-10k-warm` | the same two over other people, nine passes in the same process, the median pass |
| `tx-1k-default` | 1,000 transactions of one datom each, in each system's default commit |
| `tx-1k-durable` | 1,000 more, each commit on the device before it returns |
| `tx-1k-nosync` | 1,000 more with the commit's flush off and one sync at the end |
| `as-of+history` | the salary total as of the basis before the writes, and a `history` count |
| `create-durable`, `load-durable` | Nextomic only: `create` and `load` through a durable connection |
| `create-nosync`, `load-nosync` | `create` and `load` with the flush off and one sync at the end |

Every twin runs all three write batches, the same datoms, so the
answers and the history agree; a batch a system has no mode for runs
untimed and its row is n/a. Datalevin has no time views:
`datalevin.core`'s public vars (listed by `(ns-publics
'datalevin.core)` under `dtlv exec`) hold no `as-of`, `since` or
`history`, so that row is n/a for it. The store's size after `load` is
read with `du` (allocated blocks) and as the sum of file lengths;
Datomic Pro's is its H2 data directory after `index`, with the
transactor stopped.

**The same code.** A language workload is one body,
`bench/compare/lang/NAME.clj`, run by every implementation after a
prelude: `prelude.clj` for babashka and Clojure, one file, and
`prelude.nx`, which differs from it only in the clock and the string
namespace. The bodies
compile without a reflection warning. The database workloads are twin
scripts, `db/nexis-*.nx`, `db/dtlv-*.clj`, `db/datomic-local-*.clj`
and `db/datomic-pro-*.clj`, the same data from the same arithmetic,
the same batches and the same queries, differing only in API spelling:
Datomic Local's client API has no `entity` and no `pull-many`, so a
lookup is a `pull` of one attribute and `pull-10k` one `pull` per
entity, and its `:find` takes relations only, so a scalar answer is
the first of the first tuple; it has no `:db/index`, every attribute
being in AVET. Inputs are generated, not random, and the runner fails
a workload unless every run of every implementation prints the same
answer for every phase, so every row is equal work.

**Method.** `bb bench/compare/run.clj --out DIR [--n 10]` builds
`bin/nexis` with `-Doptimize=fast` and records the host (CPU, logical CPUs, RAM,
OS, kernel, and on Linux the frequency governor and the pinned CPUs'
maximum clocks), the versions (nexis commit and whether `src/` is
dirty, the emdb commit, Zig, `bb`, `dtlv`, the JDK, the Clojure CLI,
the JVM flags, `deps.edn`, Datomic Pro's `VERSION`), the date and the
load average before and after. `--impls` chooses the implementations
(`nexis,bb,datalevin` unless given; `clojure`, `datomic-local` and
`datomic-pro` join them, the last with `--datomic-pro DIR`, the
unpacked distribution); where `git` cannot name a commit,
`--nexis-commit` and `--emdb-commit` do. Each workload runs once per
implementation, discarded, to warm the file cache; then `--n` rounds
(at least 10; startup 3 × `--n`), the implementations alternating and
their order rotated each round. Every run is a fresh process under
`/usr/bin/time` (`-l` on macOS, GNU `-v` on Linux), and with
`--pin CPUS` under `taskset -c CPUS` (Linux), the same CPUs for every
implementation, the transactor included. A phase's time is read inside
the process with the implementation's monotonic clock (`nano-time`,
`System/nanoTime`, SCI's `system-time`) around the work alone, input
generation outside it, and each cell reports the median with the
minimum and the nearest-rank p95. Beside it the runner records each
process's wall time (spawn to exit, through the wrappers) and peak RSS
(`maximum resident set size`); the transactor's peak RSS is its
`VmHWM` from `/proc` before it is stopped. A database run creates
fresh stores, and the query phases run in a second process against
the store the first built. The runner waits for the 1-minute load
average (`vm.loadavg`, `/proc/loadavg`) to fall under `--max-load` (4)
before a workload, and a workload during which it rose above that is
discarded and repeated, up to three attempts, all kept in the JSON.
`DIR/results.md` is the table, `DIR/results.json` every run, and
`DIR/src/` the exact programs. `dtlv` runs with
`-Dorg.bytedeco.javacpp.cachedir` under `TMPDIR`, so the native
libraries it extracts land there and not under the home directory.

**The JVM runs.** Every JVM runs with the JDK's defaults (G1, the heap
sized from the RAM) plus `-XX:-UsePerfData` and `-Djava.io.tmpdir` set
to `TMPDIR`, so nothing is written under `/tmp` (the Clojure CLI adds
its own `-XX:-OmitStackTraceInFastThrow`); the report records the
flags. Clojure and Datomic Local resolve from
`bench/compare/deps.edn` (Clojure 1.12.6, `com.datomic/local`
1.0.291), with the classpath computed once before anything is timed.
A language workload runs as two Clojure processes per round: `clojure
-M NAME.clj`, the program's one run in a fresh JVM as babashka runs
it (the **cold** column), and `clojure -M warm.clj NAME.clj 20 10`,
which evaluates the program's forms once, makes its timed `let` a
function, calls it 20 times, discarded, and prints the median of the
next 10 (the **warm** column, the JIT given its due). Startup is
`clojure -M -e '(+ 1 2)'`, the CLI's launcher and its cached-classpath
check included. The Datomic Pro peer runs `java -cp` over the
distribution's own classpath (`datomic-transactor-pro-*.jar:lib/*`)
with `db/logback.xml`, warnings to stderr; the transactor is
`bin/transactor` with the distribution's JVM options (`-Xms1g -Xmx1g`,
G1, a 50 ms pause goal) and `config/samples/dev-transactor-template.properties`'s
memory settings, its data and log under the run's store directory. The
runner starts it before the load and again before the queries, so the
query peer meets a transactor that reopened the store, and stops it
after each.

**What is not comparable, and why a row may mislead.**

- *Execution.* nexis compiles to bytecode and interprets it (§6).
  babashka's SCI interprets the program too, but the Clojure library
  it calls (`sort`, `frequencies`, `group-by`, `clojure.string`,
  `reduce`, the persistent collections) is compiled ahead of time into
  the native image. Clojure compiles the program to JVM bytecode,
  which HotSpot interprets and then compiles; the cold column pays
  the class loading and the interpreter, the warm column is compiled
  code. Datalevin's engine is compiled Java and C; Nextomic's is Zig;
  Datomic's is Java and Clojure on HotSpot, and every Datomic phase is
  timed in a process that started for the run, so its first phases
  include class loading and a cold JIT; the `-warm` rows show how much
  that costs (JIT and the peer's segment cache both warm by then), and
  a long-running peer would do better on the others.
- *Sequences.* All three are lazy and chunked by 32 (`docs/LAZY.md`):
  `filter`, `map` and `map` realize a chunk at a time as `reduce`
  walks. nexis's VM keeps the intermediate seqs in its slots until the
  call returns (no locals clearing), so the pipeline row holds all
  three realized, as Clojure's would not.
- *Transients.* All three edit the nodes a transient owns in place
  (`docs/TRANSIENT.md`).
- *Durability.* The rows are grouped by what a commit guarantees when
  it returns, and what each system does was traced with `strace -f`
  over 200 one-datom transactions (Linux, `docs/PERF.md` §3.15):
  - Nextomic's default commit (`:commit`, `docs/DB.md` §3.3) syncs
    nothing: it is atomic and survives a crash of the process, and the
    file is synced once when the connection is released, outside the
    timed phase (one `fdatasync` in the trace). A connection opened
    `{:durability :durable}` syncs data and meta on every commit: two
    `fdatasync` on Linux, two `fcntl(F_FULLFSYNC)` on macOS, which
    ask the drive to empty its write cache.
  - Datalevin 1.1.0's datalog store opens with the LMDB flags
    `#{:nordahead :notls}` (`get-env-flags`) and its write-ahead log off
    (`opts` gives `:wal? false`), so a commit syncs as LMDB does: one
    `fdatasync` of the data, and the meta page written through a
    descriptor opened `O_DSYNC`. Its default commit is its durable one,
    and `tx-1k-durable` is a second batch in it. On the Apple host its
    measured cost per commit (`docs/PERF.md` §3.11) is a twentieth of
    one `F_FULLFSYNC`, consistent with `fsync(2)`, which on macOS
    returns before the drive's cache is flushed (not traced there: it
    needs root), so there its rows are weaker than Nextomic's durable
    ones.
  - Datomic Local's one commit mode syncs its log: two `fdatasync` per
    transaction. Its default commit is its durable one, and
    `tx-1k-durable` is a second batch in it; it has no no-sync mode.
  - Datomic Pro's transactor acknowledges a transaction once dev
    storage has it, and H2 buffers its writes in memory and writes the
    file in batches without a sync (no `fsync` or `fdatasync` in the
    transactor's trace; nine `pwrite64` to the H2 file over 200
    transactions and about a second). An acknowledged transaction
    survives a crash of the peer; one H2 has not yet written can be
    lost with the transactor. Its row is `tx-1k-default` alone. Datomic Pro over a production storage
    (PostgreSQL, DynamoDB, Cassandra) commits as that storage does and
    is not measured here.

  The `default` rows therefore compare different guarantees, each
  system's default, and the `durable` rows the same one. The `nosync`
  rows compare the transaction machinery alone: Nextomic's `{:sync
  :none}` per transaction and `d/sync` at the end; Datalevin's
  `:nosync` environment flag and `sync` at the end.
- *What a write stores.* Nextomic writes every datom to EAVT and AEVT,
  AVET for unique and indexed attributes, VAET for refs, the four
  history twins of those, and a txlog entry per transaction
  (`docs/NEXTOMIC.md` §2), all before the commit returns. Datalevin
  writes EAV and AVE (every attribute is in AVE; `datoms :ave` answers
  for an unindexed one) and keeps no history. Datomic writes the
  transaction to its log when it commits and folds it into its
  compressed, immutable index segments (EAVT, AEVT, AVET, VAET, and
  their history) later, in the background; the `index` row is that
  work for the whole load, which the `load` row does not include.
  Load time and store size pay for history on the nexis and Datomic
  sides. The nexis and Datomic Pro schemas mark `:person/age`
  indexed, which Datalevin and Datomic Local do without being asked.
- *Caches.* Nextomic caches a query's parse per VM; Datalevin keeps
  caches of its own (`opts` shows `:cache-limit 512`); a Datomic peer
  caches index segments in its object cache (half its heap by
  default). Every timed query in a run has inputs
  of its own, so no result can come from a result cache; the `-warm`
  rows go through `entity` and `pull`, not a query.
- *Processes.* Datomic Pro's transactor is a second JVM on the same
  host, pinned to the same CPUs; its RSS is reported on its own row
  and belongs beside the peer's. Its reads cross a local TCP socket to
  the transactor's H2 server.
- *Memory.* Peak RSS reflects each collector's policy (nexis's
  non-moving mark-sweep over the process allocator; the native
  image's collector and its heap sizing; G1 with a heap sized from
  the host's RAM) as much as live data.
- *The host.* A workstation shared with its owner: the load average is
  recorded, and a workload that saw it rise past `--max-load` is
  repeated. The frequency governor is left as the host has it (on the
  Linux host of record, `powersave`, where the clock follows the load),
  which slows short phases more than long ones for every system alike.
  Pinning keeps every process on the same class of core (on a hybrid
  CPU, the performance cores and their threads) and leaves the JVM
  its compiler and collector threads.
- *Startup* includes the wrappers' spawn (`time`, `taskset`), the
  same for all.
