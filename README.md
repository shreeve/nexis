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

**Phase 2 in progress** — language core nearly complete; ready for
reader-form integration. See [`PLAN.md`](PLAN.md) §21 for the phase map
and [`HANDOFF.md`](HANDOFF.md) for the current state + next task.

| Phase | Status | What |
|---|---|---|
| Phase 0 | ✓ shipped | Reader: grammar, `@lang` module, Form normalizer, pretty-printer, golden tests |
| Phase 1 | ✓ shipped | Runtime core: Value model, persistent collections (CHAMP HAMT, RRB vector, list), heap + GC, codec, emdb integration |
| Phase 2 | ~70% done | Compiler + VM. Steps #1-#6 of [`docs/COMPILER.md`](docs/COMPILER.md) §10 complete. Step #7 (reader-form integration → real `.nx` source files) is next. |
| Phase 3+ | pending | Macros, standard library, error reporting, golden eval pipeline, performance polish |

Working today (via the bootstrap `Tiny` AST in `src/compile.zig`):

```clojure
;; literals and arithmetic
(+ 1 2)                             ;; => 3
(< 1 2)                             ;; => true
(if (< 0 5) :yes :no)               ;; => :yes (eventually; keywords land soon)

;; let, fn, closures, captures (with control-flow-safe pre-analysis)
(let* [x 5]
  ((fn* [y] (+ x y)) 3))            ;; => 8

;; named fn* self-reference (Clojure semantics)
((fn* fact [n]
   (if (< n 2) n (recur (+ n -1))))
 5)                                 ;; => 0 (counts down; via recur, constant stack)

;; loop* + recur — constant stack, verified 10k iterations
(loop* [i 0 acc 0]
  (if (< i 10)
    (recur (+ i 1) (+ acc i))
    acc))                           ;; => 45

;; mutual recursion via letfn* placeholder cells
(letfn* [(f [n] (g n))
         (g [n] (+ n 100))]
  (f 5))                            ;; => 105

;; vars, def, defn with forward references
(do (defn f [] (g))
    (defn g [] 42)
    (f))                            ;; => 42

;; variadic & rest
((fn* [a & r] r) 1 2 3 4)           ;; => (2 3 4)
```

Step #7 (next) closes the loop: actual `.nx` source files compile
end-to-end via the reader.

## Build

```bash
zig build phase2-test              # ~3s — vm + compile tests (inner loop)
zig build test                     # ~3min — full Phase 0/1/2 suite + golden (pre-commit gate)
zig build parser                   # regenerate src/parser.zig from nexis.grammar
zig build golden                   # reader golden tests alone
```

See [`AGENTS.md`](AGENTS.md) for when to use which.

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

### What this means for a Clojure programmer

**The language design is intentionally Clojure's** — same surface
syntax, same macros, same persistent collections, same scoping rules.
A Clojure programmer **reading** nexis source recognizes the language
immediately: `let`/`fn`/`defn`/`loop`/`recur`, `#(...)` anon-fn
shorthand, `#'x` var ref, `^{...}` metadata, `[]`/`{}`/`#{}` collection
literals, Lisp-1 namespace with Vars, Clojure-style truthiness (only
`nil`/`false` are falsy), proper lexical closures with fresh-cell-per-
iteration capture for loop bindings.

**Writing productive nexis is a different story.** Two categories of
gap:

**Permanent, by design** (these never close — they're not bugs, they're
the deal):
- **No Java interop.** No `(Math/sqrt x)`, no `(.method obj)`, no
  `(import …)`. Roughly 30-40% of real-world Clojure code touches
  Java; that code does not port.
- **No STM (Refs, `dosync`, `commute`).** Channels + immutable
  values + (post-v1) durable transactions are the concurrency story.
- **No JVM ecosystem.** No Maven Central. The library story rebuilds
  on top of nexis.

**Closing as phases land:**
- Phase 2 (now): single-arity functions only, single global namespace,
  no destructuring, no stdlib, no REPL, no protocols/multimethods.
  Step #7 (next) closes the loop on compiling `.nx` source files.
- Phase 3: standard library (`map`, `reduce`, `filter`, `conj`,
  `assoc`, threading macros, etc.), multi-arity functions,
  destructuring, multiple namespaces, protocols, multimethods,
  dynamic Var binding. After Phase 3, idiomatic non-interop Clojure
  mostly ports.
- Phase 4-5: codec + emdb integration finalized.
- Phase 6: performance polish + benchmarks.
- Post-v1: Nextomic — Datomic-class temporal queries embedded as a
  library, something Clojure-on-JVM never had natively.

So: **the semantics port; the platform and the libraries don't.** A
Clojure programmer trades the JVM ecosystem for a single binary, no
JVM warmup, integrated durable storage, and a path to Datomic-class
identity. That's a real trade, not a free lunch.

See [`CLOJURE-REVIEW.md`](CLOJURE-REVIEW.md) for the line-by-line
catalogue of what we take, adapt, and reject from Clojure's source.

## What's here

| Path | Purpose |
|---|---|
| [`PLAN.md`](PLAN.md) | Authoritative design — read this first (§23 frozen decisions, §28 canonical Form schema) |
| [`HANDOFF.md`](HANDOFF.md) | Current state + immediate next task (for inter-session continuity) |
| [`AGENTS.md`](AGENTS.md) | Routing guide for contributors / AI sessions |
| [`CLOJURE-REVIEW.md`](CLOJURE-REVIEW.md) | What we take, adapt, reject from Clojure's source |
| [`docs/`](docs/) | 20 design specs — see [`docs/README.md`](docs/README.md) for the module ↔ spec map |
| [`src/`](src/) | 24 Zig modules — runtime + compiler. `vm.zig` (VM kernel) and `compile.zig` (Phase 2 compiler) are the largest. |
| [`test/`](test/) | Property tests + golden tests; most unit tests are inline in `src/*.zig`. See [`test/README.md`](test/README.md). |
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
