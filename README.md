# nexis

> **Clojure language design on a Zig-native runtime.** Same surface
> syntax, same persistent collections, same macros, same lexical
> scoping. Single binary, no JVM warmup, integrated durable storage,
> post-v1 path to Datomic-class temporal queries. **Not a Clojure
> port** — no Java interop, no STM; what you trade the JVM ecosystem
> for is described below.

**nexis** takes Clojure's best ideas — persistent immutable collections,
macros, keywords, data-first APIs, identity/value separation, lexical
closures with proper capture semantics, `let`/`fn`/`defn`/`loop`/`recur` —
and reimplements them on a vertically integrated Zig-native substrate:
a grammar-driven parser (`nexus`), an mmap'd MVCC B+ tree storage
engine (`emdb`), and a production 64-bit bytecode VM. Durable
identities are first-class values, not a library bolted on top.

## Status

**Phase 2 COMPLETE**, **Phase 3.0 COMPLETE**, **Phase 3.1 COMPLETE**,
**Phase 3.2 COMPLETE**, **Phase 3.3a COMPLETE**. Real `.nx` source
runs end-to-end through `bin/nexis run FILE.nx` AND an interactive
`bin/nexis repl`. The reader, macroexpander, compiler, and bytecode
VM all ship; host macros (`when`/`cond`/`and`/`or`/`->`/`->>`/etc.)
AND user-defined macros via `defmacro` work; syntax-quote
(`` ` ``/`~`/`~@`/auto-gensym), try/catch/finally, recoverable
error catchability, persistent maps/sets, AND the first 10
macro-authoring native fns (`list`/`cons`/`first`/`rest`/`count`/
`nth`/`empty?`/`identity`/`nil?`/`some?`) are all in.

See [`PLAN.md`](PLAN.md) §21 for the phase map and
[`HANDOFF.md`](HANDOFF.md) for current state + next task.

| Phase | Status | What |
|---|---|---|
| Phase 0 | ✅ shipped | Reader: grammar, `@lang` module, Form normalizer, pretty-printer, golden tests |
| Phase 1 | ✅ shipped | Runtime core: Value model, persistent collections (CHAMP HAMT, RRB vector, list), heap + GC, codec, emdb integration |
| Phase 2 | ✅ shipped | Compiler + bytecode VM. 11/11 steps of [`docs/COMPILER.md`](docs/COMPILER.md) §10 complete. All 7 gate items from §9.4 satisfied. |
| Phase 3.0 | ✅ shipped | CLI runner + REPL, anonymous-fn shorthand `#(...)`, catchable VM errors |
| Phase 3.1 | ✅ shipped | Persistent maps `{:k 1}` and sets `#{1 2}` as runtime literals |
| Phase 3.2 | ✅ shipped | User-defined `defmacro` with compile-time evaluation (fresh sub-VM per invocation) |
| Phase 3.3a | ✅ shipped | 10 native fns for macro authoring (`list`/`cons`/`first`/`rest`/`count`/`nth`/`empty?`/`identity`/`nil?`/`some?`); `Kind.native_fn` infrastructure |
| Phase 3.3b+ | pending | `VM.callValue` + `apply` + higher-order fns (`map`/`reduce`/`filter`) + first-class arithmetic Vars + collection utilities (`assoc`/`get`/`conj`) + `core.nx` embed + multi-namespace |

**558 tests** green: 95 VM + 313 compile + 6 macroexpand + 4
property + 54 integration in `phase2-test` (~3s), plus 86 reader
+ golden tests, plus the Phase 1 randomized property tests.

## Build & run

```bash
zig build install                  # produces bin/nexis, bin/nexis-bench, bin/nexis-golden

./bin/nexis run examples/hello.nx          # run a file
./bin/nexis repl                            # interactive REPL
./bin/nexis --help                          # usage
```

For developers:

```bash
zig build phase2-test              # ~3s — fast inner-loop test suite
zig build test                     # ~3min — full Phase 0/1/2 suite + property tests
zig build parser                   # regenerate src/parser.zig from nexis.grammar
zig build bench                    # ReleaseFast benchmark suite
zig build golden                   # reader golden tests alone
```

See [`AGENTS.md`](AGENTS.md) for when to use which.

## Working today

Every snippet runs via `bin/nexis`. Run the file or paste into the REPL:

```clojure
;; arithmetic + comparison + conditionals
(+ 1 2)                             ;; => 3
(if (< 0 5) :small :big)            ;; => :small

;; bindings — user-facing `let` (rename macro to let*)
(let [x 1 y 2] (+ x y))             ;; => 3

;; functions + closures with proper capture
(let [x 5]
  ((fn [y] (+ x y)) 3))             ;; => 8

;; constant-stack recursion via recur (verified 10k iterations)
(loop [i 0 acc 0]
  (if (< i 10)
    (recur (+ i 1) (+ acc i))
    acc))                           ;; => 45

;; mutual recursion via letfn*
(letfn* [(f [] (g))
         (g [] 99)]
  (f))                              ;; => 99

;; variadic & rest
((fn* [a & r] a) 1 2 3 4)           ;; => 1

;; vars + forward references
(do (defn f [] (g))
    (defn g [] 42)
    (f))                            ;; => 42

;; lexical shadowing follows scope
(let [+ (fn [a b] 99)]
  (+ 1 2))                          ;; => 99 (+ shadowed)

;; macros (when/when-not/and/or/cond/->/->>/let/fn/loop)
(when (and 1 :truthy)
  (or false :got-it))               ;; => :got-it

(-> 1 (+ 2) (+ 3))                  ;; => 6

(cond
  (< 1 0) :impossible
  :else   :reachable)               ;; => :reachable

;; or/and use gensym so side-effects evaluate once
(or false nil :found)               ;; => :found

;; quote scalar + quote compound
(quote 42)                          ;; => 42
(quote (1 2 3))                     ;; => (1 2 3)
(quote [a b c])                     ;; => [a b c]

;; syntax-quote with unquote + splicing
(let [xs (quote (b c d))]
  `(start ~@xs end))                ;; => (start b c d end)

;; auto-gensym (each `g#` in one syntax-quote scope gets the same name)
`(let* [g# 1] g#)                   ;; => (let* [g__N__auto__ 1] g__N__auto__)

;; user-defined macros via defmacro (Phase 3.2)
(defmacro unless [test body]
  `(if ~test nil ~body))
(unless false :got-it)              ;; => :got-it

;; variadic defmacro with splicing
(defmacro my-when [test & body]
  `(if ~test (do ~@body) nil))
(my-when true :a :b :c)             ;; => :c

;; defmacro is visible to subsequent forms in same do-block
(do (defmacro twice [x] `(+ ~x ~x))
    (twice 21))                     ;; => 42

;; persistent maps + sets as first-class values (Phase 3.1)
{:a 1 :b 2}                         ;; persistent map
#{1 2 3}                            ;; persistent set

;; native fns for macro authoring (Phase 3.3a)
(list 1 2 3)                        ;; => (1 2 3)
(cons 0 (list 1 2 3))               ;; => (0 1 2 3)
(first [10 20 30])                  ;; => 10
(rest (list :a :b :c))              ;; => (:b :c)
(count {:a 1 :b 2})                 ;; => 2
(empty? nil)                        ;; => true (nil-as-empty-seq)

;; user-written PROCEDURAL macro using native fns at compile time
(defmacro my-cond [& clauses]
  (if (empty? clauses)
    nil
    `(if ~(first clauses)
       ~(first (rest clauses))
       (my-cond ~@(rest (rest clauses))))))
(my-cond false :a true :b false :c) ;; => :b

;; anonymous-fn shorthand
(#(+ % 1) 41)                       ;; => 42
(#(+ %1 %2) 10 20)                  ;; => 30

;; try/catch/finally with cross-frame unwinding
(try
  (throw :bang)
  (catch any e e)
  (finally :always-runs))           ;; => :bang

;; VM-detected errors are catchable (Phase 3.0c)
(try (+ 1 :not-a-number)
  (catch any e e))                  ;; => :kind-mismatch

(try (+ 1 undefined-var)
  (catch any e e))                  ;; => :unbound-var
```

Compile errors carry file:line:col + a source caret:

```text
$ echo '(when)' > bad.nx && bin/nexis run bad.nx
nexis: bad.nx:1:1: MacroExpansionFailure
    (when)
    ^^^^^^
```

## Still missing (closes in Phase 3.3b+)

These are temporary gaps, not strategic non-goals — each unlocks
when its phase ships:

- **Higher-order fns**: `map`/`reduce`/`filter`/`apply` need
  `VM.callValue` (reentrant VM execution) — Phase 3.3b.
- **First-class arithmetic Vars**: `(reduce + 0 xs)` needs `+`
  to resolve to a Var, not just inline at the call head —
  Phase 3.3b.
- **Collection ops**: `assoc`/`dissoc`/`get`/`conj`/`keys`/`vals`
  — Phase 3.3c.
- **`core.nx` embedded stdlib**: composite macros + fns written
  in nexis (`when-let`/`if-let`/`dotimes`/...) — Phase 3.3d.
- **Multi-namespace**: single global namespace today.
  `(require ...)`/`(use ...)`/qualified symbols are Phase 3.4.
- **Multi-arity `defn`**: `(defn f ([x] …) ([x y] …))` not supported.
- **Destructuring**: `(let [{:keys [a b]} m] …)` etc. — Phase 3.5.
- **Protocols / multimethods**: post-stdlib.
- **Runtime SrcSpans**: runtime errors (UncaughtThrow etc.)
  don't carry source spans yet — bounded post-gate work.

## Permanent differences from Clojure/JVM

These never close — they're trade-offs, not bugs:

- **No Java interop.** No `(Math/sqrt x)`, no `(.method obj)`, no
  `(import …)`. Roughly 30-40% of real-world Clojure code touches
  Java; that code does not port.
- **No STM** (`ref`, `dosync`, `commute`). Channels + immutable
  values + (post-v1) durable transactions are the concurrency story.
- **No JVM ecosystem.** No Maven Central, no Leiningen. The library
  story rebuilds on top of nexis.

**The semantics port; the platform and the libraries don't.** A
Clojure programmer trades the JVM ecosystem for a single binary, no
JVM warmup, integrated durable storage, and a path to Datomic-class
identity. That's a real trade, not a free lunch.

See [`CLOJURE-REVIEW.md`](CLOJURE-REVIEW.md) for the line-by-line
catalogue of what we take, adapt, and reject from Clojure's source.

## What makes this different

| Dimension | Clojure-on-JVM | nexis |
|---|---|---|
| Host runtime | JVM (~150 MB resident, 1-3s startup) | Zig-native binary (~5 MB target, instant) |
| Compilation target | JVM bytecode | Custom 64-bit ISA ([`docs/VM.md`](docs/VM.md)) |
| GC | JVM (G1 / ZGC / etc.) | Precise mark-sweep tracing (Phase 1, shipped) |
| Persistent collections | Bagwell HAMT + plain 32-way vector | CHAMP HAMT + RRB vector (modern designs) |
| Concurrency | JVM threads + STM (Refs) | Single-isolate v1; multi-isolate via channels later |
| Java interop | Yes (huge) | None (intentional — keeps the runtime tight) |
| Durable storage | External (Datomic, JDBC, etc.) | First-class: emdb integrated; `durable_ref` is a Value kind |
| Deployment | JVM uberjar / native-image | Static binary, end-state ~5 MB |

## What's here

| Path | Purpose |
|---|---|
| [`PLAN.md`](PLAN.md) | Authoritative design — read this first (§23 frozen decisions, §28 canonical Form schema) |
| [`HANDOFF.md`](HANDOFF.md) | Current state + immediate next task (for inter-session continuity) |
| [`AGENTS.md`](AGENTS.md) | Routing guide for contributors / AI sessions |
| [`CLOJURE-REVIEW.md`](CLOJURE-REVIEW.md) | What we take, adapt, reject from Clojure's source |
| [`docs/`](docs/) | 20 design specs — see [`docs/README.md`](docs/README.md) for the module ↔ spec map |
| [`src/`](src/) | Zig modules — runtime + compiler. `vm.zig` (VM kernel), `compile.zig` (compiler), and `expand.zig` (macroexpander) are the largest. |
| [`test/`](test/) | Property tests, integration tests, golden tests; most unit tests are inline in `src/*.zig`. See [`test/README.md`](test/README.md). |
| [`examples/`](examples/) | Working `.nx` programs — `hello.nx`, `cond.nx`, `threading.nx`, `macro-author.nx`, `defmacro.nx`, `try-catch.nx`, `syntax-quote.nx`, `sum10.nx`, `forward-ref.nx`, `macros.nx`, `quoted-list.nx`, `maps-sets.nx`. |
| [`nexis.grammar`](nexis.grammar) | Reader grammar — source of truth for `src/parser.zig` |
| [`ZIG-0.16.0.md`](ZIG-0.16.0.md) | Project-specific Zig 0.16 stdlib reference + gotchas (MANDATORY before writing Zig) |

## Requirements

- **Zig 0.16.0** (pinned; stdlib changed substantially between 0.15 and
  0.16). See [`ZIG-0.16.0.md`](ZIG-0.16.0.md) for the gotchas that have
  actually bitten us.
- **nexus** at `../nexus/bin/nexus` for `zig build parser`.
- **emdb** as a path dependency (see `build.zig.zon`).

## Post-v1 vision: Nextomic

A Datomic-class embedded database, built as a nexis library on top of
emdb. Not a v1 deliverable; the substrate is intentionally designed to
support it without retrofitting. See [`docs/NEXTOMIC.md`](docs/NEXTOMIC.md)
for the architecture reference.

## License

TBD (v1 ships under a permissive license).
