## BENCH.md — Benchmarking Methodology & Reporting Discipline

**Status**: Phase 1 deliverable (methodology only — no benchmark code yet).
This document pre-commits to the shape of every performance claim nexis
will make about itself, especially in comparison to Clojure. Landing
before any benchmark code or numbers exist is intentional: the
commitments here are strongest when they cannot be post-rationalized
against favorable measurements.

Derivative from `PLAN.md` §19.6 / §19.7 / §19.8 (performance Tier 1/2
targets and perf-gate text). PLAN.md wins on conflict.

---

### 1. Three claims, four standards

Every performance claim published by nexis must satisfy four
independent standards, not three:

1. **Numerical** — measured, not asserted. Wall-clock time (or
   allocated bytes, or RSS, or whatever) from a real run, with units.
2. **Accurate** — multiple runs with statistical reporting (§3),
   controlled hardware (§4), documented methodology, reproducibility
   instructions that let a third party rerun and match within noise.
3. **Fair** — idiomatic code on every side, standard tooling, stock
   configuration, no cherry-picking either direction. Would a
   competent practitioner of the other language read the source and
   say "yes, that's a reasonable way to write this"?
4. **Relevant** — the benchmark measures something that corresponds
   to a real user workload or a specific architectural claim nexis is
   making. A microbenchmark that doesn't ladder up to a user-facing
   scenario is noise.

A benchmark that fails any one of these is withdrawn, not re-framed.

---

### 2. Category taxonomy — every claim pinned to a regime

Performance does not have one number. Clojure has three legitimate
performance regimes (cold JVM start, warmed but short-lived,
fully-hot JIT'd steady state), and mixing them is the fastest way to
produce a dishonest chart. nexis has its own regimes (cold-start
interpreter, warm interpreter loop, future Phase 6 specialized ops).

Every published measurement must be tagged with exactly one category:

| Category | Measures | Typical tool |
|---|---|---|
| **Startup** | Time-to-first-expression or CLI-to-result on a fresh process | `hyperfine` |
| **Short-lived script** | Total wall time for a small program that runs once and exits | `hyperfine` |
| **Warm microbenchmark** | Per-operation cost after warm-up, on hot code | `criterium` (Clojure) / custom harness (nexis) |
| **Steady-state throughput** | Operations per second on a long-running warmed workload | `criterium` (Clojure) / custom harness (nexis) |
| **Collection construction** | Build-an-N-element collection (persistent vs transient paths reported separately) | Custom harness |
| **Collection lookup/update** | get/assoc/conj/dissoc over various sizes | Custom harness |
| **Memory footprint** | Peak RSS and/or allocated-bytes under a reproducible workload | OS-level (GNU `time -v` / macOS `/usr/bin/time -l`) |
| **Database-integrated** | End-to-end workloads touching emdb / durable refs | Custom harness + hyperfine |
| **Macrobenchmark** | Realistic user program end-to-end | `hyperfine` + shell harness |

Published claims like "2–4× faster on arithmetic-heavy code" must
specify: which category, which regime, which input size, which
idiom tier. Headline PLAN.md numbers (§19.6) are restated with
category labels at publication.

---

### 3. Statistics — what we report, what we don't

- **Median**, not mean. Arithmetic mean in the presence of GC pauses
  (Clojure) or page-fault outliers (either side) produces misleading
  summaries.
- **p5 / p95 / p99** alongside median. Lets readers see tail
  behavior; lets us detect when GC pauses dominate.
- **Minimum run count**: 30 for warm microbenchmarks, 10 for
  startup / macro workloads (which are slower to run). For
  `criterium`-backed Clojure microbenchmarks, use its default
  estimation + sampling strategy.
- **Report distribution visually** when publishing a full report —
  box plots or violin plots, never a bar chart of a single
  number with no error bar.
- **Never report speedup multiples without absolute numbers.**
  "2.3×" is unpublishable without the underlying ms or ns/op. The
  multiplier can mask cases where both implementations are already
  fast enough that the ratio doesn't matter.
- **Never report means across heterogeneous workloads.** A
  "geomean across benchmarks" table is noise without per-benchmark
  context and hides cherry-picking.

---

### 4. Hardware & environment

Every published result documents:

- CPU model (exact, e.g., "Apple M4 Pro, 12-core, 2025").
- RAM amount and type.
- OS + kernel version.
- Whether the machine was idle (no other meaningful work).
- CPU-frequency scaling setting (`performance` governor on Linux;
  noted-and-disclaimed on macOS where user control is limited).
- Thermal state if relevant (long-running benchmarks may throttle).

Cross-machine results are not comparable. A benchmark suite
published at v1 ship runs on one canonical machine; the exact machine
is documented. Re-running on other hardware is encouraged and
published separately with full disclosure.

---

### 5. Clojure-side fairness — conventions we adopt

These are community-standard and omitting them is a credibility
mistake per peer-AI methodology review (`nexis-phase-1` turn 4):

- **`criterium`** for every microbenchmark. `(require '[criterium.core :refer [quick-bench bench]])`. Non-criterium timing of Clojure microbenchmarks is rejected by default.
- **`*warn-on-reflection*` is enabled** for every benchmark file and
  every warning is resolved before measurement. Reflection is a
  canonical anti-idiom; presence in a benchmark file is treated as
  evidence of incompetence by the Clojure community regardless of
  whether it affects the specific hot path.
- **Primitive arithmetic explicitly tiered.** When benchmarking
  arithmetic, publish three variants:
  1. Idiomatic generic Clojure (boxed).
  2. `^long` / `^double` hinted primitive Clojure.
  3. `unchecked-*` primitive Clojure with `*unchecked-math* true`.
  Each row in the results table names the tier. Comparing nexis's
  tagged-fixnum path against generic boxed Clojure and implying
  "nexis is faster than Clojure arithmetic" is explicitly forbidden.
- **Transients are used where the community would.** Building a
  collection via `(into [] ...)` (which uses transients internally),
  `(persistent! (reduce conj! (transient coll) xs))`, or equivalent
  for the fast path. Pure-persistent `conj` loops are benchmarked
  separately and labeled as the persistent-only tier.
- **Versions pinned.** Clojure 1.12.x on the current JDK LTS release,
  stock server flags, no `-XX:+UseZGC` / `-XX:+UseEpsilonGC` /
  `-Xshare:off` tweaks in the baseline. A "tuned JVM" appendix
  with explicitly disclosed flags is optional; never the headline.
- **Graal native-image is not used** in baseline comparisons. It's a
  separate deployment story; if measured, it's its own row in the
  table labeled accordingly.

---

### 6. nexis-side fairness — what we hold ourselves to

The symmetric rules, enforced on our own side:

- **Baseline benchmarks use the v1 interpreter**. Once Phase 6
  optimizations land (SIMD CHAMP, perfect-hash keywords, operand-
  specialized ops), those are published as their own rows labeled
  as optimization-tier measurements, not folded into the baseline.
- **Idiomatic nexis code**, not hand-unrolled core-primitives
  invocation. When stdlib macros like `defn`, `->>`, `reduce`
  land, they are used in the benchmark code the same way a nexis
  user would use them.
- **No disabled safety paths for benchmark runs.** Everything runs
  with the same runtime safety settings a user would run. If a
  "release-unsafe" variant is published, it's its own row and
  labeled.
- **Bytecode vs JIT disclosure.** Phase 6 Tier 2 work includes
  opcode specialization but not a real JIT; Phase 7+ Tier 3 may add
  copy-and-patch. Claims like "faster than Clojure's JIT steady-
  state" are labeled explicitly — nexis's advantages come from
  architecture (tagged values, CHAMP, xxHash3), not from execution
  strategy. Readers shouldn't have to infer that.

---

### 7. Reproducibility — the non-negotiable part

Every published benchmark must ship with:

1. **Source code checked into `test/bench/`** for both sides
   (`bench/<name>.nx` and `bench/<name>.clj`), with a `README.md` in
   the same directory pinning:
   - exact command lines,
   - input data generation (seeded),
   - expected approximate output shape (so readers can sanity-check
     a rerun against the published numbers).
2. **Raw data** published alongside the report, not just summaries
   (CSV or JSON per-run).
3. **Exact versions**: nexis commit SHA, Clojure version, JDK build
   number, OS version, hardware.
4. **A "hermeticity" shell script** that runs the suite
   end-to-end from a clean checkout; if it doesn't reproduce the
   published numbers within p5/p95 noise on the documented hardware,
   the report is wrong and must be corrected.

Unreproducible benchmarks are withdrawn, not patched post-hoc.

---

### 8. The honesty clause

**Scenarios where Clojure wins are published, not omitted.** This is
credibility engineering, not altruism. A report that claims universal
victory is trusted by nobody who has shipped a language before. A
report that says "nexis dominates cold start and script-style
workloads; competitive-to-faster on collection work; Clojure's JIT
wins on long-running hot numeric inner loops until Phase 6 Tier 2
opcode specialization lands" is believable because it admits the
obvious.

Concretely:

- At least one published benchmark per category where Clojure is
  ahead (if any exist in that category). Manufactured symmetry is
  worse than admitted losses; if there genuinely are no losses in a
  category, state so explicitly rather than filler.
- Mixed-result workloads (nexis ahead on some inputs, Clojure ahead
  on others) get both lines plotted.
- Worst-case numbers (p99) are shown alongside medians so readers see
  tail behavior on both sides.
- Any result where measurement variance is > 20% is either
  investigated and republished or withdrawn. Don't publish noisy
  numbers dressed up with decimals to look precise.

---

### 9. Pre-publication review

Before any comparative benchmark report is published:

- **Internal review.** The report is posted as a draft in the repo
  (PR or tagged branch) for at least 7 days with open comment
  before release.
- **External Clojure-community review.** At least one Clojure
  practitioner outside the nexis team reviews the Clojure source
  code of every benchmark and signs off that the implementation is
  reasonable and idiomatic. A single such reviewer saying "this is
  fair Clojure" buys far more credibility than any internal
  discipline; omitting this step invites post-hoc dismissal.
- **Issues raised during review are resolved before publication**,
  not relegated to footnotes. If a reviewer objects to a specific
  benchmark's framing and their objection is defensible, the
  benchmark is rewritten or withdrawn.

---

### 10. What this doc does not cover

- **Specific benchmark content.** `test/bench/` populates as Phase 6
  lands; each benchmark gets its own `README.md` per §7. This doc
  is methodology, not suite design.
- **Benchmark-driven performance tuning.** PLAN §19 defines the
  Tier 1/2/3 wins with projected magnitudes; Phase 6 is where they
  get measured and published. This doc is the publication contract,
  not the implementation plan.
- **Marketing copy.** Headline positioning (PLAN §19.7) is allowed
  to be aspirational; the comparative benchmark report is where
  aspirations meet measurement and must survive that collision.

---

### 11. Summary sentence for any future report

Every comparative benchmark report nexis publishes must be
introducable with, and survive the test of, the following sentence:

> "We measured several clearly defined performance regimes, with
> published source and methodology, and here is where nexis is
> faster, where it is comparable, and where Clojure wins."

If a reported result cannot be defended under that sentence, it
does not ship. This doc exists so nothing needs to be post-
rationalized.
