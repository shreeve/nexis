## CLOJURUST.md — nexis beside clojurust

clojurust (<https://github.com/csm/clojurust>, its binary `cljrs`) is
Clojure implemented in Rust. This note sets nexis 0.4.0 beside
clojurust 0.1.0 at commit `b847a29b`, each built optimized. It is a
comparison, not a spec; a statement here about clojurust holds for
that commit. The speed and memory numbers of record are in
`docs/PERF.md` §3.43.

The two share a goal, Clojure without a JVM, and differ in what they
spend on it. clojurust aims at Clojure's whole surface, with threads,
a JIT and Rust interop. nexis aims at a small, fast, single-threaded
runtime with a database in the same binary.

---

## 1. The two designs

| | nexis | clojurust |
|---|---|---|
| Written in | Zig: about 71,000 lines with the `.nx` library, inline tests included | Rust: 23 crates, about 120,000 lines without tests, and 22,600 of Clojure |
| Execution | bytecode, threaded-dispatch VM, no JIT | tree-walking interpreter, then an SSA IR compiled by a Cranelift JIT (type specialization, inline caches, on-stack replacement, deoptimization) |
| Ahead-of-time output | none | `cljrs compile`, which runs `cargo build` and needs a Rust toolchain; a 21.6 MB binary |
| Value | 16-byte tagged | a Rust `enum` |
| Collector | precise, non-moving mark-sweep | non-moving mark-sweep, scanning JIT frames conservatively, with escape-analysis regions |
| Collections | CHAMP maps and sets, 32-way vectors | `rpds`, HAMT and RRB structures |
| Hash | xxHash3 | Murmur3, Clojure's values |
| Threads | one | `future`, `promise`, core.async over Tokio, a heap per isolate; no agents, refs or STM |
| Persistence | Nextomic and durable refs over emdb | none; `cljrs-tx` is a sandbox for transaction functions and stores nothing |
| Numbers | fixnum, bignum, f64 (PLAN §23 #10) | those, ratios and BigDecimal |
| Binary | 3.7 MB, static on Linux | 39 MB |
| Dependencies | emdb, compiled in; Nexus at build time | 668 crates in `Cargo.lock` |
| License | MIT | EPL-1.0 |

---

## 2. Speed and memory

`docs/PERF.md` §3.43 holds the table. On ten single-threaded programs
on an Apple M5, nexis is ahead of clojurust on every one: 21–401×
against its JIT and 13–498× against its AOT binary. `sort` of a million
ints takes 38 ms in nexis and does not finish in 120 s in either
clojurust form. clojurust peaks at 6–8 GB on the programs that
allocate most, where nexis peaks at 35–188 MB. An empty program takes
7.1 ms and 4.3 MB in nexis, 14.1 ms and 18.4 MB in clojurust.

These programs are nexis's own comparison set. None uses a thread, so
none measures what clojurust's concurrency buys.

---

## 3. Clojure fidelity

**The differential run.** 1,963 expressions in fourteen categories,
each in its own process through babashka, clojurust and nexis. The
1,811 that babashka itself evaluates are scored, a row agreeing when
its output is identical, apart from set print order and object
addresses. babashka is the oracle because no JVM was installed; it
runs Clojure 1.12's surface through SCI.

| Category | Rows | clojurust | nexis |
|---|---:|---:|---:|
| numbers | 190 | 79% | 57% |
| floats | 79 | 72% | 67% |
| strings | 143 | 84% | 82% |
| collections | 333 | 86% | 90% |
| destructuring | 129 | 87% | 98% |
| lazy sequences | 111 | 78% | 85% |
| protocols and records | 93 | 59% | 65% |
| macros and syntax-quote | 199 | 55% | 55% |
| reader | 62 | 35% | 37% |
| metadata | 67 | 79% | 78% |
| exceptions | 117 | 59% | 56% |
| dynamic vars | 83 | 64% | 60% |
| atoms and concurrency | 81 | 57% | 35% |
| libraries | 124 | 60% | 62% |
| **all** | **1,811** | **71.6%** | **69.9%** |

The totals tie, and they measure different things. Of nexis's 546
misses, 517 are differences its documents state: no ratios, decimals,
Java interop or threads, errors as maps, code-point string indexes
(`CLOJURE-REVIEW.md` §3, §4). The other 29 are `TODO.md` #30. Of
clojurust's 515 misses, 157 are the absence of a JVM host and 358 are
a missing name, a wrong answer or a wrong print.

**Answers.** Each of these was run through all three binaries;
babashka and nexis agree on every row:

| Expression | babashka and nexis | clojurust |
|---|---|---|
| `1e21` | `1.0E21` | `1000000000000000000000` |
| `(assoc-in [[1 2]] [0 1] 9)` | `[[1 9]]` | `{0 {1 9}}` |
| `(let [[a b] "hi"] [a b])` | `[\h \i]` | `[nil nil]` |
| `(let [{:keys [a] :or {a 9}} {:a nil}] a)` | `nil` | `9` |
| `(= 1 1.0)` | `false` | `true` |
| `(flatten nil)` | `()` | `(nil)` |
| `#inst "2020-01-02T00:00:00Z"` | an instant | a string |
| `(as-> 1 x (inc x))` | `2` | an internal error, `unsupported binding pattern` |

`if-some`, `macroexpand-1`, `reductions`, `while`, `trampoline`,
`sorted-map-by` and `agent` do not resolve in clojurust; nexis has all
of them but `agent`.

**Answers that change under the JIT.** A builtin warmed on valid input
and then given an edge case answers differently from the same call
cold on 34 of 240 inputs. Compiled, `(/ 1 2)` is `0` where the
interpreter gives `1/2`, and `(/ 1 0)` and `(nth [1] 9)` are `nil`
where they should raise. `alter-var-root`, `eval` and `vary-meta`
raise once hot. nexis has one execution tier, so a call answers alike
however often it has run.

**Soundness under load.** `swap!` is not atomic in clojurust: four
`future`s of 300,000 `(swap! a inc)` each end at 639,189 and 781,906
in two runs, against 1,200,000 in babashka. A `read-string` 100,000
levels deep, a chain of `concat`s and a deep `eval` end in a SIGBUS;
`(quot Long/MIN_VALUE -1)` is a panic no `catch` reaches. A JIT frame
keeps everything it allocates until it returns, so a hot allocating
loop reaches 2 GB where the IR tier holds 180 MB. In the same probes
nexis neither crashed nor hung, deep inputs raising
`:stack-overflow`.

**Names.** Of `clojure.core` 1.12's 676 public vars, babashka has
93.8%, clojurust 68.9% and nexis 64.2%. What nexis lacks is mostly the
JVM host and threads; the rest is `use`, `refer` and `alias`, `reify`
and `deftype`, the printer and I/O dynamic vars, and the names in
`TODO.md` #30.

**clojure-test-suite.** clojurust passes all of its copy, 7,155
assertions across 258 namespaces with no failures, in 2.8 s. That copy
carries 91 `:rust` reader-conditional branches, 18 of them exclusions,
and the suite touches about a third of `clojure.core`. nexis does not
read `.cljc` (`docs/GUIDE.md`), so its run goes through a converter:
138 of 257 files run, with 2,016 assertions passing and 27 failing.
Of the files that do not run, 64 hold a BigDecimal literal and 21 a
ratio literal. Coercing those literals, which weakens the tests that
hold them, 4,591 pass and 316 fail.

---

## 4. Tools, errors and deployment

| | nexis | clojurust |
|---|---|---|
| Commands | `run`, `repl`, `test`, `disasm`, `doc`, `-e` | `run`, `repl`, `test`, `eval`, `compile`, `deps`, `ir` |
| Editor | colouring for VS Code, Vim and highlight.js | nREPL; LSP with symbols and syntax diagnostics |
| Packages | none | `cljrs deps`, from git |
| Interop | `nexis.shell/sh`, `nexis.sys` | Rust interop, dynamic libraries |
| Networking | none | TCP, UDP, TLS through core.async; HTTP fetch |
| An error's report | file, line, column, the source line, a caret and a stack, on every error | a located box for a parse error; a one-line message or an `#error` map, without a place, at runtime |
| Exit codes | 3 reader, 4 compile, 5 runtime | 1 |
| Docs | a spec per module, `doc`, `dir`, `apropos`, `docs/GUIDE.md` | a 5,000-line book, a README per crate |
| Install | a static binary with checksums; a source build needs the private emdb | `cargo`, a Rust toolchain for AOT |

clojurust's README lists `agent` as implemented; `(agent 0)` does not
resolve in this commit.

---

## 5. Where each leads

**nexis:** speed and memory on every workload measured (§2); start-up;
binary size and dependencies; correctness of ordinary Clojure code
(§3); destructuring, collections, lazy sequences and macro tooling;
error reports; one tier, whose answers do not change as code warms;
the database, which clojurust has no counterpart to.

**clojurust:** threads and asynchrony; networking; nREPL and an LSP;
packages from git; Rust interop; ahead-of-time binaries; a process
memory governor, gas limits and cancellation; ratios and
BigDecimal, with the numeric fidelity they buy; the published
clojure-test-suite, which nexis cannot read directly.

What nexis lacks here is `HANDOFF.md` §8's next work: threads, sockets
and a server mode, nREPL, packages.
