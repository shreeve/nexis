# PLAN.md — nexis

**A modern, Zig-native Lisp inspired by Clojure, built for persistent data and performance.**

---

## 🚨 Start here — for a fresh AI implementation session

**Read this block before anything else. Everything below assumes you have.**

### What this document is

`PLAN.md` is the **authoritative design specification** for nexis. It is the product of deep iterative review (including 10 rounds of adversarial critique with a peer AI and a direct read of ~30k lines of Clojure source). Commitments in §23 (Hard Decisions) require an amendment to this document to change. Everything else may be refined during implementation but should respect the architecture laid out here.

### Required reading (in order)

1. **This document** (`PLAN.md`) — end to end. It's long (~2400 lines) but every section exists for a reason. Budget 60–90 minutes.
2. **`CLOJURE-REVIEW.md`** (at repo root) — documents what we take / adapt / reject from Clojure's actual source code, and why. Explains the rationale behind many decisions in this PLAN.
3. **`ZIG-0.16.0-REFERENCE.md`** and **`ZIG-0.16.0-QUICKSTART.md`** (at repo root) — **mandatory** before writing any Zig. 30+ stdlib APIs changed between 0.15 and 0.16 in ways that will silently break code from training data.

### Local resources available to you (absolute paths)

| Path | What it is | How to use it |
|---|---|---|
| `misc/clojure/` (in this repo) | **Full Clojure source code** — 42k lines of Java + 8k lines of `core.clj` | Read freely. We take architectural ideas, not code. The files studied in CLOJURE-REVIEW.md are listed there with line counts. |
| `/Users/shreeve/Data/Code/nexus/` | **Parser generator** — produces `src/parser.zig` from `nexis.grammar` | Read `README.md` and `nexus.grammar` there for the grammar DSL. Study `test/zag/zag.grammar` and `test/slash/slash.grammar` for real-world examples. em's `mumps.grammar` is also a high-quality reference. |
| `/Users/shreeve/Data/Code/emdb/` | **Storage engine** — mmap'd B+ tree, MVCC, named trees | Read `README.md` and `SPEC.md`. This is what nexis uses for durable refs (§15). |
| `/Users/shreeve/Data/Code/em/` | **MUMPS engine** — template for compiler/bytecode/runtime | Read `docs/architecture/ISA.md` for the 64-bit bytecode format we inherit. `src/mumps.zig` shows the `@lang` module contract. `src/mumps.grammar` shows a real production grammar. |

### Companion documents (some exist, some to produce)

| Doc | Status | Purpose |
|---|---|---|
| `CLOJURE-REVIEW.md` | ✅ exists at repo root | Source review findings (230 lines) |
| `docs/SEMANTICS.md` | **to produce in Phase 0** | Numeric corner cases (NaN, -0.0, ±Inf, overflow), print/read contract, cross-type equality examples, nil/empty semantics, metadata matrix (§8.5) |
| `docs/FORMS.md` | **to produce in Phase 0** | Canonical Form schema (lift from Appendix C §28 for easy reference), reader-to-Form normalization rules, reader/normalizer/macroexpander responsibility boundaries |
| `docs/CODEC.md` (stub) | **to produce in Phase 0** | Serializability matrix (from §15.10), wire format, round-trip invariants |
| `AGENTS.md` | **to produce in Phase 0** | Short routing guide: "read PLAN.md end-to-end, then CLOJURE-REVIEW.md, then ZIG-0.16.0-REFERENCE.md; follow §23 frozen decisions; see §24 for open questions." |

### Your Phase 0 deliverables

Detailed in §21, but summarized:

- `nexis.grammar`, `src/nexis.zig`, `build.zig`, `build.zig.zon` — the parser and build wiring
- `docs/SEMANTICS.md`, `docs/FORMS.md`, `docs/CODEC.md` (stub)
- `test/golden/basic.{nx,sexp}`, `test/golden/reader-literals.{nx,sexp}`, `test/golden/errors/*`
- `README.md` updated, `AGENTS.md` created
- Directory layout per §22

**Exit**: grammar parses, forms match Appendix C shapes, SEMANTICS.md is reviewed, all golden tests pass.

### How to navigate this document

- **TOC below** is 28 sections + 3 appendices.
- **Appendix C (§28)** is the single most important artifact for Phase 0 — the canonical Form schema with worked examples.
- **§23 Hard Decisions** is the list of 38 frozen commitments. If you're about to do something that contradicts one, STOP and ask.
- **§24 Open Questions** is what's deliberately not decided yet — those are your call, guided by the design principles (§3).
- **§25 Risk Register** — 17 named risks with mitigations. Refer to this when tempted to shortcut.

### Non-negotiable discipline

1. **Do not break the three-representations boundary** (§5): Form, Value, Durable Encoded are distinct layers. They never fuse except through explicit codec operations.
2. **Respect the SCVU operand-kind encoding** (§12.2): hot-path S/C/V/U, context-local I/J/E.
3. **Do not widen the v1 non-goals list** (§4) without writing an amendment.
4. **Do not expose benchmarks publicly** until Phase 6 runs real numbers (§19.7). The plan intentionally under-promises and over-delivers.

If any of this conflicts with what you believe the user wants, **ask**. Do not silently deviate from frozen decisions.

---

## Table of Contents

0. [Executive Summary](#0-executive-summary)
1. [Positioning](#1-positioning)
2. [Substrate](#2-substrate)
3. [Design Principles](#3-design-principles)
4. [Non-Goals for v1](#4-non-goals-for-v1)
5. [Three Representations (kept distinct)](#5-three-representations-kept-distinct)
6. [Language Semantics](#6-language-semantics)
7. [Reader & Syntax](#7-reader--syntax)
8. [Value Model](#8-value-model)
9. [Persistent Collections](#9-persistent-collections)
10. [Memory Management](#10-memory-management)
11. [Compiler Pipeline](#11-compiler-pipeline)
12. [Bytecode & ISA](#12-bytecode--isa)
13. [Runtime](#13-runtime)
14. [Macros & Namespaces](#14-macros--namespaces)
15. [Durable Identities (emdb Integration)](#15-durable-identities-emdb-integration)
16. [Concurrency & Isolation](#16-concurrency--isolation)
17. [Standard Library Shape](#17-standard-library-shape)
18. [Tooling](#18-tooling)
19. [SIMD & Performance](#19-simd--performance)
20. [Testing Strategy & Phase Gates](#20-testing-strategy--phase-gates)
21. [Roadmap & Milestones](#21-roadmap--milestones)
22. [Repository Layout](#22-repository-layout)
23. [Hard Decisions (Frozen)](#23-hard-decisions-frozen)
24. [Open Questions (Deferred)](#24-open-questions-deferred)
25. [Risk Register](#25-risk-register)
26. [Appendix A — Comparison With Clojure](#26-appendix-a--comparison-with-clojure)
27. [Appendix B — Worked Examples](#27-appendix-b--worked-examples)
28. [Appendix C — Canonical Form Schema](#28-appendix-c--canonical-form-schema) — the authoritative parser/reader contract

---

## 0. Executive Summary

**nexis** is a new programming language and runtime, implemented in pure Zig 0.16.0, that takes the deepest ideas from Clojure — persistent immutable values, macros, keywords, data-oriented APIs, identity/value separation — and replants them on a vertically integrated substrate we already own:

- **`nexus`** — a grammar-driven parser generator that emits a single Zig lexer + LALR(1) parser producing S-expressions directly.
- **`emdb`** — a memory-mapped, copy-on-write, MVCC B+ tree with zero-copy reads, SIMD acceleration, and named sub-databases.
- **`em`** — a production MUMPS engine whose 64-bit bytecode ISA, slot/register VM, tail-call dispatch, and routine architecture serve as the proven template for the nexis compiler/bytecode/runtime.

nexis is **not** Clojure-in-Zig, and **not** a Common Lisp retrofit. It is a Lisp whose language semantics, runtime representation, and durable identity model are designed together from the start, so that the programmer sees **one coherent model** of immutable values, transactional durable identity, and interactive development.

### The one-sentence mission

> A Lisp where immutable values, transactional durable identity, and historical snapshots are one coherent programming model.

### The v1 test

You can:

1. Launch a REPL.
2. Define functions, macros, namespaces.
3. Manipulate persistent maps, sets, vectors with Clojure-style ergonomics.
4. Put a value into emdb and get it back with stable equality/hash.
5. Open a write transaction, update several durable identities, and observe atomic commit.
6. Redefine a function at the REPL and have live call sites see the new root.
7. Profile bytecode execution and disassemble compiled code.

Nothing more; nothing less. If v1 does only this, but does it elegantly and fast, nexis is already differentiated.

### The performance aspiration

Every architectural decision in this document either directly enables or preserves a concrete performance win. See §19.6 for the full tier-structured analysis. The **targets** (not promises) we aim for, in defined benchmark suites, against current Clojure on the JVM:

- **Dramatically lower cold start** (mmap'd bytecode, no class-loading, no JIT warmup) — measured target in `bench-startup.nx`.
- **Lower per-op arithmetic overhead** (16-byte tagged Value vs JVM Object reference + heap header) — measured target in `bench-vm.nx`.
- **Competitive or better map lookup** on medium maps once SIMD CHAMP nodes are in place — measured target in `bench-collections.nx`.
- **Substantially faster database reads** of large strings/blobs via zero-copy paths from emdb mmap — measured target in `bench-db.nx`.
- **Very high throughput on typed-vector numerics** via native `@Vector(N, T)` SIMD kernels — measured target in `bench-simd.nx`.

Specific multiplier claims are **withheld until Phase 6 benchmarks against Clojure produce real numbers**; the numbers in §19.7 are projections based on well-understood structural advantages, published alongside v1 with honest side-by-side comparisons. We intend the phrase *"fastest interpreter-tier Lisp ever shipped"* as an aspirational north star, not a shipping commitment.

---

## 1. Positioning

### What nexis is

- A **Lisp**, unapologetically. s-expressions, macros, code-as-data.
- **Clojure-inspired**, not Clojure-derived: persistent collections, keywords, `[]`/`{}`/`#{}` literals, threading macros, destructuring.
- **Zig-native**: the compiler, runtime, GC, collections, and storage bridge are all pure Zig 0.16.0.
- **emdb-infused**: durable identity is a first-class language concept, not a library bolted on top.
- **Performance-minded**: slot/register VM, tail-call dispatch, SIMD-ready homogeneous typed vectors, zero-copy reads from storage.

### What nexis is not

- Not Clojure-compatible. Source, classpath, protocols, STM, agents, `core.async`, multimethods, reader conditionals, tagged literals — all deliberately absent from v1.
- Not a Common Lisp derivative. No ANSI CL package system, no `loop` macro as specified in CLtL2, no multiple-value returns, no `CLOS`.
- Not a JVM language, not hosted. No host interop bias. FFI is Zig-level only.
- Not a research project. Nothing ships in v1 that is not already proven in some existing system.

### The differentiator

Most languages split these concerns apart:

- language values
- runtime representation
- storage representation
- concurrency model

Clojure's strongest card was making *values* the unit of exchange. nexis goes one step further:

> **A durable identity is an ordinary value.** You can hold one in a local, pass it to a function, put it in a map, and it compares equal and hashes consistently by its identity, never by the dereferenced contents. Deref reads; `alter` updates; transactions compose.

That is the story. Everything else in this plan exists to make that story real without making the language feel like a database wrapper.

---

## 2. Substrate

nexis does not start from scratch. It stands on three production-quality pillars:

| Pillar | Role for nexis | Lines | Maturity |
|---|---|---|---|
| `nexus` | Generates `src/parser.zig` from `nexis.grammar`. Emits `Sexp` trees directly. | ~7.3k Zig | Self-hosting, 3 real languages validated. |
| `emdb` | Embedded storage engine. Named B+ trees, MVCC, zero-copy reads. | ~10k Zig | 82 formally specified invariants, 169 integration tests. |
| `em` | Template for the compiler → bytecode → runtime pipeline. 64-bit ISA, tail-call VM, slot machine, routine cache. | ~32k Zig | MUMPS-feature-complete, VistA-runnable. |

### What we borrow directly

- **Parser generation workflow**: `nexis.grammar` → `bin/nexus nexis.grammar src/parser.zig`. Same build step as em.
- **ISA shape**: 64-bit fixed-width instructions, 6-bit group + 6-bit variant + 3× (4-bit kind + 12-bit index), 20-bit extension form for overflow. Proven efficient.
- **Dispatch**: tail-call dispatcher (primary) with two-level switch fallback (for platforms without reliable tail calls).
- **Frame/slot model**: per-routine slot pool, per-routine literal/variable/entry tables, shared constant pool.
- **Routine cache**: memory-mapped compiled object code, on-disk format reused with a new magic and payload encoding.
- **Key encoding**: emdb's collated key format is adopted wholesale for any ordered storage.
- **SIMD utilities**: em's key comparison, prefix scan, page copy reused in the storage bridge.

### What we do not borrow

- MUMPS-specific value semantics (18-digit BCD decimals, string/number dual coercion, `$ORDER` collation rules as language default).
- MUMPS-specific opcode groups (`indir`, `isv`, much of `str`, `patterns.zig` NFA).
- MUMPS-specific global reference model (`^GLOBAL(sub1,sub2)`).
- The `Val` 24-byte layout (see §8 — nexis uses 16 bytes).

em taught us *how* to build a fast native Lisp-shaped bytecode VM on Zig. nexis is a different language with its own semantic core built on the same engine architecture.

### 2.1 Lineage — prior art we consciously borrow from

Nothing in nexis is conceptually new. Every major design choice has a clear ancestor in working production software. We are combining proven ideas from five distinct traditions:

| Tradition | What we take | Where it shows up |
|---|---|---|
| **LMDB** (Howard Chu, 2011) | Memory-mapped B+ tree, copy-on-write pages, MVCC via dual meta-page commit, no-WAL crash safety, single-writer multi-reader concurrency | `emdb` — our storage engine is LMDB-class, pure-Zig, with added SIMD and prefix compression |
| **Datomic** (Rich Hickey, 2012) | Database-as-value semantics, identity-as-stable-handle, time as first-class, snapshots as cheap values | `nexis.db` — durable refs, `with-tx` / `with-read-tx`, snapshot handles, future `as-of` reads |
| **Clojure** (Rich Hickey, 2007) | Persistent immutable collections, keywords, `[]`/`{}`/`#{}` literals, macros + syntax-quote + auto-gensym, namespaces + vars, REPL redefinition, threading macros | Essentially the surface language |
| **CHAMP** (Steindorfer & Vinju, OOPSLA 2015) | Bitmap-indexed trie with separate data/node bitmaps, canonicalization for equality speed | `src/coll/hamt.zig` — persistent map and set |
| **RRB Trees** (Bagwell & Rompf, 2011) | Relaxed radix balanced tree for vectors with fast `concat` and `subvec` | `src/coll/rrb.zig` — persistent vector |
| **LuaJIT** (Mike Pall) | Register/slot VM, tail-call dispatch, operand-specialized opcodes (`ADDVV`/`ADDVN`), fixnum fast paths | The em-inherited ISA + our planned Phase 6 specialization |
| **Lua 5.0** (Ierusalimschy et al., 2005) | Upvalue closure representation, register-based VM simplicity | Closure and upvalue model |
| **Copy-and-Patch JIT** (Xu et al., PLDI 2021) | Template-based near-native code generation with ~500 LOC of glue | Future v2 JIT path (§19.5) |
| **Scheme R7RS / Racket** | Tail-call correctness, `syntax-rules` spirit (without full hygiene), error-as-value thinking | Tail call discipline, `try`/`catch`/`finally` model |
| **xtdb / datahike / Datascript** | Proof that LMDB-class engines can host Datomic-class semantics in open-source Clojure | Validation that our `emdb` + nexis substrate can support a full Datalog-query-capable database library — see §15.11 |

The rule we follow:

> **If a good idea exists in a proven system, take it. If an idea is novel, we treat it as research and keep it out of v1 unless cheap.**

This list is not exhaustive, but it pins the reference points. When a design choice is contested, the first question is: "What does LMDB / Datomic / Clojure / LuaJIT do?" If two of them agree, we usually follow.

---

## 3. Design Principles

Eleven principles. Every architectural decision in this document is checkable against these.

1. **Values first.** The unit of programming is an immutable value. Update produces a new value with structural sharing.
2. **Identity separate from value.** A `Var`, an isolate-local cell, or a durable ref has an identity whose *value* may change over time. Identity and value are never confused.
3. **Persistent by default.** Default map/set/vector are HAMT/CHAMP/RRB-tree structures. Mutation is opt-in through narrow, scoped `transient` windows.
4. **Heap values and durable values share semantics, not necessarily representation.** Two values are equal iff they compare equal under `=`, regardless of whether one is heap-resident and one materialized from emdb.
5. **Durable identity is explicit.** There is no "maybe durable" value. A durable ref is a distinct, visibly-named kind.
6. **One coherent model.** The user sees one story for values, identities, transactions, and persistence. No impedance mismatch.
7. **Minimal reader, macro-powered surface.** The reader handles only what cannot be expressed as a macro: literals, collection punctuation, quote/unquote/deref/metadata.
8. **Interactive development is sacred.** REPL redefinition, macroexpand, disassembly, introspection are first-class. They are not "tooling added later."
9. **Explicit, predictable performance.** No hidden laziness, no surprise boxing, no implicit allocations in hot loops.
10. **Separation of concerns.** Reader/Form, runtime Value, and durable encoding are three distinct layers. They may share conventions; they never fuse until benchmarks justify it.
11. **Boring first, brilliant later.** Start with the simplest thing that is known to work. Optimize only with measurements. Research lives in a branch.

---

## 4. Non-Goals for v1

An aggressive list of things nexis **deliberately does not ship** in v1. Each is an invitation to revisit later, not a rejection forever.

| Feature | Rationale |
|---|---|
| User-extensible protocols | Pick a built-in polymorphism story first. Protocols have deep compile/dispatch implications. |
| Multimethods | Elegant, but overkill before the core universe of types is stable. |
| Software transactional memory | emdb transactions are the language transaction story. A second concurrency model is a trap. |
| Agents | Historical JVM-era artifact. Isolates + message passing subsumes the use case. |
| `core.async` | Huge semantic and scheduling sink. Not needed for v1. |
| Reader conditionals `#?(...)` | Nexis does not have multiple compile targets in v1. |
| Tagged literals `#inst`, `#uuid`, `#myns/foo` | Rich literals can be macros or functions; add selectively later. |
| Rational numbers | Deferred. Number tower is int + bigint + f64 only. |
| Lazy sequences everywhere | Eager by default. Streams/iterators are a separate, opt-in abstraction later. |
| Forcing every collection fast path through `seq` | `seq` is a core language abstraction (see §6.6), but direct map lookup, vector indexing, and typed-vector kernels remain first-class fast paths. |
| Regular expression literals | Regex is a library call in v1. |
| Multiple compile targets (JVM / JS / native) | Zig-native only. |
| Multi-isolate runtime / parallelism | v1 is single-process, single-isolate, single-threaded (§16). |
| Content-addressed values | Interesting; changes storage and identity semantics too deeply to pull in now. |
| Time-travel debugging | As-of reads on durable state are in scope; full execution history replay is not. |
| Full hygienic macros (Scheme-style) | Auto-gensym + syntax-quote qualification only. |
| Property system / validators / watches | Out of v1. |
| Type inference / gradual typing | Dynamic typing only in v1. Schema/spec is a library idea for later. |
| Native code generation (JIT/AOT) | Bytecode only. |
| Threads, futures, promises | Out of v1. |
| FFI beyond Zig-level | No libc binding layer in v1. |

**Every feature on this list is an explicit decision, not an oversight.** When the feature's absence is cited as a complaint, the answer is: "Yes. On purpose. Here's the rationale."

---

## 5. Three Representations (kept distinct)

The single most important discipline in the entire plan:

### Layer 1 — Reader / Form

The product of parsing source text. Immutable tree of syntactic data.

- `Form = { datum, origin, user_meta, ann }` — a recursive heap-resident wrapper type, **not** a side table.
- `datum` is an atomic datum or a compound of Forms (list/vector/map/set).
- `origin` is `{ pos, len, file, id }`, derived from `Sexp.src`.
- `user_meta` is whatever `^{...}` attached in source, normalized to a map form by the reader.
- `ann` is an inline optional field holding compiler annotations: macro-expansion provenance, resolved symbol info, namespace of origin. Invisible to user code; never affects equality.
- **Why inline, not side-tabled:** macro expansion creates many fresh Forms; a global side-table would require stable node identity we'd have to invent, churn on every copy/transform, and complicate debugging. Inline fields travel with the Form.
- Macros consume `Form`, produce `Form`.

### Layer 2 — Runtime Value

The product of the compiler; what bytecode manipulates. 16-byte tagged value (§8).

- Immediates: `nil`, `bool`, `char`, `fixnum`, interned `keyword` id, interned `symbol` id.
- Heap kinds: string, bignum, f64 box (if not inline), persistent map, persistent set, persistent vector, byte vector, typed vector, list (cons), function/closure, var, durable-ref, transient wrapper, error. (Records deferred to v2; see §24.)
- Equality is structural for collections, identity-like for durable refs and vars, standard IEEE comparisons for floats (with a defined total-order for hashing/sort where floats participate).

### Layer 3 — Durable Encoding

The byte representation of a value written to an emdb B+ tree. Self-describing tagged wire format:

- `[kind:u8][flags:u8][len:varint][payload...]` (exact format specified in §15).
- Schema-aware encoders may elide redundant type tags.
- Ordered keys use emdb's collation format from em.
- Round-trip invariant: `decode(encode(v)) = v` under `=` and `hash`.

**These three layers do not leak into each other.** The compiler does not emit Forms as runtime values (except through `quote` which transparently lifts them). The storage layer does not read raw runtime Values; it always goes through the codec.

Violating this discipline is how language projects turn into tar pits.

---

## 6. Language Semantics

### 6.1 Compiler-known primitives vs user-facing forms

The compiler recognizes a **small primitive core**. User-facing ergonomics (`let`, `fn`, `loop`, `letfn`, `defn`, destructuring, docstrings, multi-arity sugar) live in macros and standard library code, not in the compiler. This follows Clojure's successful `*`-form split: the compiler stays boring; macros provide the surface language.

#### Compiler-known primitives

| Primitive | Semantics |
|---|---|
| `(quote x)` | Yield `x` unevaluated as a Form-lifted value. |
| `(if p t e?)` | Truthy-branching conditional. Only `nil` and `false` are falsy. |
| `(do e1 e2 ... eN)` | Sequential evaluation; yield `eN`. Empty `(do)` is `nil`. |
| `(let* [b1 v1 b2 v2 ...] body...)` | Primitive lexical binding. No user-facing sugar beyond flat bindings. Destructuring is macro-lowered before this stage. |
| `(fn* name? [params...] body...)` | Primitive function creation. The compiler knows only the lowered form. Multi-arity, docstrings, pre/post conditions, and other surface sugar are macro concerns. |
| `(letfn* [name1 init1 name2 init2 ...] body...)` | Primitive mutually-recursive local function binding. |
| `(loop* [b1 v1 b2 v2 ...] body...)` | Primitive loop form establishing a `recur` target. |
| `(recur args...)` | Rebind nearest enclosing `loop*` or function arity and jump. Guaranteed constant-space. |
| `(def sym init?)` | Define or redefine a `Var` in the current namespace. |
| `(throw e)` | Raise `e` as an exception value. |
| `(try body... (catch bind pat handler) (finally cleanup))` | Exception handling. Frames with pending `finally` / unwind obligations are not tailcall-replaceable. |
| `(var sym)` | Yield the `Var` object (not its root value). |
| `(set! target expr)` | Narrowly scoped: only rebinds the current dynamic binding of a `^:dynamic` Var. Errors on ordinary locals, collections, or non-dynamic vars. Var root rebinding is via `def` / `alter-var-root!`, not `set!`. |

#### User-facing forms provided as macros

| User form | Lowers to |
|---|---|
| `(let [bindings...] body...)` | `(let* [...lowered bindings...] body...)` |
| `(fn name? clauses...)` | `(fn* ...lowered clauses...)` |
| `(loop [bindings...] body...)` | `(loop* [...lowered bindings...] body...)` |
| `(letfn [bindings...] body...)` | `(letfn* [...lowered bindings...] body...)` |
| `(defn name doc? attrs? clauses...)` | `(def name (fn name clauses...))` after macro-level processing of docstrings, attrs, and arities |

**Two-stage bootstrap applies**: early `stdlib/core.nx` defines trivial renaming macros (`let → let*`, `fn → fn*`, `loop → loop*`, `letfn → letfn*`) first, then later redefines richer surface macros once destructuring helpers and the rest of the macro system are available. This mirrors Clojure's `core.clj` bootstrap sequence exactly.

### 6.2 Truthiness

Only `nil` and `false` are falsy. Everything else (including `0`, `""`, empty collections) is truthy. This matches Clojure; the alternative (Common Lisp-style `nil` = empty list) reintroduces ambiguity we deliberately avoid.

### 6.3 Equality and hashing

Two levels of equality, with frozen semantics:

- `identical?` — pointer/identity equality. `(identical? x x) => true`. Used rarely, mostly for performance tests and ref comparisons.
- `=` — value equality:
  - **Numeric**: within-type structural (`(= 1 1)` true), cross-type `false` in v1 (`(= 1 1.0)` false — see §8.3).
  - **Collections**: structural within equality category (see §6.6 — sequential, map, set — with cross-category always false).
  - **Vars and durable refs**: identity-based (see §13.3, §15.2).
  - **Metadata**: **never** participates.

Clojure's `==` for cross-type numeric equality is deferred to v2; v1 users who want `(= 1 1.0)` → true must explicitly cast.

Hashing:

- `hash(x) = hash(y)` whenever `(= x y)`. Non-negotiable.
- `hash` is stable across the lifetime of a process; not necessarily stable across processes unless the value is serialized (in which case the codec fixes the hash).
- Metadata **never** affects hash.
- A value's hash is cached on the heap object where cheap (heap header `hash: u32`).
- **One user-visible semantic hash function**, not two. (Clojure exposes `hashCode` and `hasheq` because of JVM interop; we have no such obligation.)
- Collection hash construction is per-category to satisfy the equality invariant:
  - **Sequential** (list, vector, lazy-seq, cons): ordered hash `h = 31*h + hasheq(x)` per element, finalized with count.
  - **Map / set**: unordered hash `h += hasheq(entry)`, finalized with count. Order-independent by construction.

### 6.4 Error model

- Errors are **thrown** (exceptions), not returned as values. Clojure-like.
- An exception is a map-bearing value (kind `:error`) with at minimum `{:message, :kind, :cause?, :trace}`.
- Stack traces carry source spans resolved back through Form origin metadata.
- `try`/`catch`/`finally` semantics:
  - `finally` runs on every exit path.
  - Transactions unwind correctly: an exception inside `(with-tx ...)` aborts the transaction.
  - `catch` binds a pattern (symbol or destructuring map) and runs against matching exception `:kind`.

### 6.5 Nil propagation on collection ops

Pragmatic, Clojure-compatible defaults:

| Operation | On `nil` |
|---|---|
| `(count nil)` | `0` |
| `(seq nil)` | `nil` |
| `(get nil k)` | `nil` |
| `(get nil k default)` | `default` |
| `(first nil)` | `nil` |
| `(rest nil)` | `()` (empty list) |
| `(conj nil x)` | `(list x)` |
| `(assoc nil k v)` | `{k v}` (a new map) |

These are frozen because they determine the ergonomic feel of the language.

### 6.6 Cross-type collection equality

Following Clojure's proven rule, collection equality partitions into **three categories**. Within a category, equality is structural element-wise. Across categories, equality is always `false`.

| Category | Members | Equality rule |
|---|---|---|
| **sequential** | `list`, `vector`, lazy `seq`, cons cells | Element-wise, in order. `(= (list 1 2 3) [1 2 3])` → `true` |
| **map** | persistent-map, array-map | Element-wise on key/value pairs, order-independent |
| **set** | persistent-set | Element-wise membership, order-independent |

- `(= [1 2 3] #{1 2 3})` → **false** (cross-category)
- `(= {:a 1} [:a 1])` → **false** (cross-category)
- `(= () nil)` → **false** (nil is not a sequential; empty-list is)
- `(= (list) [])` → **true** (both empty sequentials)
- `(= (map inc [1 2 3]) [2 3 4])` → **true** (map returns sequential; vector is sequential)

This rule is **frozen** because it determines the ergonomic feel of the language. Most idiomatic nexis code will rely on it implicitly.

**Hash consistency**: the `(= a b) ⇒ (= (hash a) (hash b))` invariant is preserved by making all sequential-category collections use the same **ordered hash** (`hash = 31 * h + hasheq(x)` per element, finalized with count). All map-category collections use the same **unordered hash** (`hash += hasheq(entry)`). Set-category is unordered too, using `hash += hasheq(elem)`. So a list and a vector with the same elements compute identical hashes by construction.

### 6.7 `seq` abstraction

nexis commits to **`seq` as the core iteration and collection-interoperability abstraction** in v1. This is confirmed after studying Clojure's own source: `seq` is not optional — it's one of the first things `core.clj` defines, and `RT.first` / `RT.next` / `RT.rest` / `RT.cons` / `RT.count` all funnel through it.

- Every persistent collection provides a defined `.seq()` view.
- Core iteration-oriented functions (`seq`, `first`, `next`, `rest`, sequence traversal in library code) are specified in terms of this abstraction.
- Nil propagation follows §6.5: `(seq nil) = nil`, `(first nil) = nil`, `(rest nil) = ()`, and related collection defaults remain stable.
- This does **not** mean every high-throughput API must funnel through `seq`. Direct map lookup, direct vector indexing, typed-vector kernels, and other performance-sensitive operations may bypass `seq` entirely when that is the clearer or faster path.

In short: `seq` is central to language-level iteration semantics, but not a straitjacket on runtime implementation strategy.

---

## 7. Reader & Syntax

### 7.1 Philosophy

**Minimal reader. Macro-powered surface.** The reader only handles what must precede macro expansion.

### 7.2 Reader grammar (authoritative list for v1)

Defined in `nexis.grammar`, run through `nexus` to produce `src/parser.zig`.

| Syntax | Reads as |
|---|---|
| `nil`, `true`, `false` | Immediates |
| `42`, `-1`, `0x2A`, `0b101` | Integer literal |
| `3.14`, `1e9`, `1.5e-3` | f64 literal |
| `\a`, `\space`, `\newline`, `\u{2603}` | Character (Unicode scalar). Named set: `\newline \space \tab \return \formfeed \backspace`. Any char via `\u{HEX}`. |
| `"..."` | String with `\n \t \r \\ \" \u{HEX}` escapes (same `\u{HEX}` form as char literals — unified escape language); no multi-line |
| `:kw`, `:ns/kw` | Keyword (auto-interned) |
| `foo`, `ns/foo`, `foo?`, `set!`, `<=`, `->>` | Symbol |
| `(a b c)` | List |
| `[a b c]` | Vector |
| `{:a 1 :b 2}` | Map; odd count = read-time error; duplicate *statically-detectable* literal keys = syntax-normalization (compile-time) error |
| `#{1 2 3}` | Set; duplicate *statically-detectable* literal elements = syntax-normalization error |
| `'x` | `(quote x)` |
| `` `x `` | Syntax-quote (auto-qualifies symbols, supports auto-gensym `x#`) |
| `~x` | Unquote |
| `~@x` | Unquote-splice |
| `@x` | `(deref x)` |
| `#(+ 1 %)` | Anonymous function shorthand; `%`, `%1`, `%2`, `%&` positional args |
| `^:kw x`, `^{...} x`, `^Type x` | Metadata (covered in §7.3) |
| `; comment` | Line comment |
| `#_ x` | Discard next form (works on metadata-annotated forms too: `#_^:x [1 2 3]`) |
| `(comment ...)` | Block-style comment via macro; body is discarded at compile time |

**Not in v1:** reader conditionals `#?`, tagged literals `#inst`, regex literals `#"..."`, syntax-quote unquote in non-list contexts (i.e. unquote only in syntax-quoted code).

### 7.3 Metadata sugar

- `^:kw x` attaches `{kw true}` to `x`.
- `^{:a 1} x` merges the map into `x`'s metadata.
- `^sym x` attaches `{:tag sym}` (reserved for future type/schema hints; ignored by compiler in v1).
- Metadata is preserved on the Form and on collection/symbol runtime values. Metadata **never** affects equality or hash.

### 7.4 Reader/Form vs Sexp

The nexus parser already emits a `Sexp` union. The reader layer wraps that into `Form`:

```zig
pub const Form = struct {
    datum: Datum,                    // atom, list, vector, map, set
    origin: ?SrcSpan,                // { file_id, pos, len }
    user_meta: ?*PersistentMap,      // ^:kw, ^{...} — normalized to map at read time
    ann: ?*Annotation,               // inline: macro provenance, resolved ns, expansion parent
};
```

The reader reads Forms; macros consume/produce Forms; the compiler lowers Forms to IR. **User metadata and compiler annotations live on different fields** so user code cannot accidentally strip crucial provenance. Both are inline on the Form — no global side-table.

---

## 8. Value Model

### 8.1 Physical layout

**16 bytes, tagged, plain struct. No NaN-boxing in v1.**

```zig
pub const Value = packed struct {
    tag: u64,      // kind + flags + interned-index hint
    payload: u64,  // pointer, fixnum, or interned id
};
```

Tag word layout (bit fields, little-endian):

| Bits  | Field           | Notes |
|-------|-----------------|-------|
| 0..7  | `kind: u8`      | Primary discriminator (see §8.2) |
| 8..15 | `flags: u8`     | `has_meta`, `hash_cached`, `durable`, reserved |
| 16..31| `subkind: u16`  | For heap kinds, the object's sub-type |
| 32..63| `aux: u32`      | Per-kind auxiliary: length prefix, bit count, cached hash lo bits |

Payload:
- Immediate kinds: the value itself (i48 fixnum sign-extended, f64 for inline-float, intern id for kw/sym).
- Heap kinds: aligned pointer to heap object.

### 8.2 Value kinds (v1)

Immediates (no heap allocation, no refcount):

| Kind | Payload | Notes |
|---|---|---|
| `nil` | unused | Singleton |
| `bool` | 0 or 1 | Singleton per value |
| `char` | u32 | Unicode code point |
| `fixnum` | i48 sign-extended | Covers ±140 trillion; fast path for all integer ops |
| `keyword` | u32 intern id | `:foo`, `:ns/foo` |
| `symbol` | u32 intern id | `foo`, `ns/foo` |
| `float` | f64 bits | Inline 64-bit float (tag word consumed) |

Heap-allocated (payload = pointer to heap object with its own header):

| Kind | Sub-types |
|---|---|
| `string` | UTF-8 strings with optional small-string optimization in the object |
| `bignum` | Arbitrary-precision integers (for fixnum overflow) |
| `persistent-map` | HAMT (§9) |
| `persistent-set` | HAMT (§9) |
| `persistent-vector` | RRB-tree (§9) |
| `list` | Immutable cons cell (used primarily by the reader/macros) |
| `byte-vector` | Packed `u8`, SIMD-friendly |
| `typed-vector` | i32, i64, f32, f64 variants, homogeneous, SIMD-friendly |
| `function` | Compiled routine + captured upvalues |
| `var` | Namespace-indirected cell (§14) |
| `durable-ref` | `{store-id, tree-id, key-bytes}` identity handle |
| `transient` | Mutable wrapper with `{owner-token, frozen?, kind}` |
| `error` | Exception value |

*(Records with named fixed fields are deferred to v2 — see §24.10. v1 uses tagged maps for record-like data.)*

All heap objects share a header:

```zig
pub const HeapHeader = packed struct {
    kind: u16,         // finer-grained than Value.tag.kind
    mark: u8,          // GC bits
    flags: u8,         // has_meta, interned, immutable, etc.
    hash: u32,         // cached hash (0 = uncomputed)
    meta: ?*PersistentMap, // optional metadata
};
```

### 8.3 Number tower (v1)

Deliberately minimal:

- `fixnum` (i48) and `bignum` form the integer tower; promotion on overflow.
- `float` (f64) is a separate type. `(= 1 1.0)` is **false**; use `(== 1 1.0)` helper if cross-type numeric equality is desired.
- No rationals. No decimals. No complex.
- Division of two integers yielding a non-integer result raises `:type-error` unless one operand is explicitly floated (`(/ 1.0 3)`), matching integer arithmetic discipline.
- *(Decimal support can be resurrected later by borrowing em's Math module wholesale — the infrastructure is proven.)*

### 8.4 Interning — keyword / symbol asymmetry

nexis adopts a deliberate **keyword / symbol asymmetry**, directly informed by Clojure's source-level design:

- **Keywords** are globally interned and represented as compact immediate values in the common case. They carry **no metadata**. Equality and hashing are cheap intern-id operations. Keywords are a language-level callable lookup form; see §8.7.
- **Symbols** are semantically distinct from keywords. In the common case, a plain symbol is represented compactly via an interned identifier for fast equality and hashing. A **metadata-bearing symbol** is a heap object wrapping a base symbol id plus a metadata map. This preserves Clojure-style symbol metadata without forcing every symbol through heap allocation.
- **Strings** are *not* interned by default. Explicit `(intern s)` remains available for hot-path deduplication where profiling justifies it.
- Interned ids are stable only within a running process. On serialization, both keywords and symbols are emitted in **textual form**, never as process-local intern ids. On deserialization, the receiver re-interns into its own tables.
- The intern table interface is future-proofed for eventual multi-isolate use, but v1 assumes a single process / single isolate / single thread.

This split is intentional: keywords are the compact, metadata-less, lookup-oriented atom; symbols are the macro- and namespace-facing atom and may carry metadata when needed.

**Hash domain separation**: a keyword and a same-named symbol must hash to different values to avoid HAMT collision when both appear as keys in the same map. Clojure uses a golden-ratio offset (`0x9e3779b9`) on the keyword hash relative to its underlying symbol; nexis adopts the same pattern (exact constant chosen with our hash algorithm).

### 8.5 Metadata semantics

- Metadata is a `persistent-map` reachable via the heap header's `meta` slot.
- Set via `with-meta`, read via `meta`.
- Metadata does not affect equality, hash, `print`, or serialization (unless explicitly requested).

#### Metadata attachability matrix (v1 — frozen)

| Kind | Can carry metadata? | Notes |
|---|---|---|
| `nil` | ❌ | Singleton immediate. `(with-meta nil m)` → throws `:no-metadata-on-immediate` |
| `bool` | ❌ | Singleton per value |
| `char` | ❌ | Unicode scalar immediate |
| `fixnum` | ❌ | Number tower |
| `bignum` | ❌ | Number tower (implementation-detail heap kind, but numeric-semantic) |
| `float` | ❌ | Number tower |
| `keyword` | ❌ | By design — keywords are metadata-less lookup atoms (§8.4) |
| `string` | ❌ | v1 decision; may revisit if needed |
| **`symbol`** | ✅ | Plain symbol is interned; attaching metadata yields a heap-wrapped symbol (§8.4) |
| **`persistent-map`, `persistent-set`, `persistent-vector`, `list`** | ✅ | All persistent collections |
| **`byte-vector`, `typed-vector`** | ✅ | Specialized homogeneous vectors |
| **`function` / closure** | ✅ | For `:arglists`, `:doc`, `:macro`, `:static`, etc. |
| **`var`** | ✅ | The primary carrier for `:macro`, `:dynamic`, `:private`, `:tag`, `:doc` |
| `durable-ref` | ❌ | v1 decision; metadata would confuse identity semantics |
| `transient` | ❌ | Mutable by definition; no metadata |
| `error` | ✅ (implicit) | An exception value IS a map; its "metadata" is its payload |

Attempting `with-meta` on a non-attachable kind throws `:no-metadata-on-immediate`. This matrix is frozen; adding a kind to the "yes" column requires a PLAN.md amendment.

### 8.6 Durable refs (summary; §15 for full semantics)

A `durable-ref` is a heap object with payload `{store-id, tree-id, key-bytes}`. It is:

- An **identity**, not a cached value.
- Equal to another durable-ref iff all three components match byte-for-byte.
- Hashed from the identity tuple, **not** from the dereferenced value.
- `deref`-able: reads the current (or snapshot-bound) stored value through the appropriate transaction.
- Not a Clojure ref or atom. Do not describe them as such. They are a distinct construct; see §15.

### 8.7 Keyword-as-function

Keywords are a **v1 language-level feature**, not a late optimization. This reflects Clojure's own design: `Keyword` implements `IFn` as a core class property.

- `(:k m)` is equivalent to `(get m :k)`.
- `(:k m default)` is equivalent to `(get m :k default)`.
- Other arities are an error (`:arity-error`).

This applies to maps and other lookup-capable values that participate in `get`. The callable behavior is part of keyword semantics and is visible in the compiler (can be specialized), runtime (built into the keyword value's dispatch), and standard library from day one.

---

## 9. Persistent Collections

### 9.1 Map and Set — CHAMP (committed target)

- **32-way branching** (5 bits per level), maximum depth 7 for 32-bit hashes.
- **CHAMP layout** (Steindorfer & Vinju, OOPSLA 2015): bitmap-indexed nodes with **separate bitmaps** for data entries and child nodes. Not the classic Bagwell single-bitmap-mixed-array layout Clojure uses.
- Data entries are stored contiguously in one region of the node's array; node entries in the other — enabling fast iteration without null-skip, faster equality via bitmap pre-check, and ~15–30% smaller heap footprint per node.
- Canonical representation: CHAMP guarantees a unique layout for any logical set of entries, enabling bitmap-level early-exit equality.
- Collision nodes only at depth limit, containing a small linear scan list.
- Hash function: **xxHash3-64** truncated to 32-bit for indexing, full 64 retained for cached-hash fields on collections.
- Small-map optimization: arrays of up to **8 entries** use a flat array-map representation before promoting to a CHAMP node tree. (Clojure uses 16; 8 is the CHAMP paper's recommendation.)
- Keyword-keyed maps use identity (`==`) equality as the fast-path key compare (since keywords are interned). Other keys go through structural `=`.

*(Fallback to classic HAMT single-bitmap layout is available if CHAMP implementation produces an unforeseen blocker, but CHAMP is the target — not a stretch goal.)*

### 9.2 Vector — plain 32-way persistent vector (v1)

v1 ships a **plain 32-way persistent vector with a tail buffer**: the same broad shape Clojure has shipped successfully for 17+ years and the same structure Clojure's own source uses today (no relaxed balancing).

- **32-way branching** (5 bits per level), radix trie layout.
- **Tail buffer** for `conj` = amortized O(1) append.
- `nth` / `assoc` remain efficient and predictable.
- `pop` is efficient when it only affects the tail or a short path back into the trie.
- **Small-vector optimization**: up to 32 elements stored inline in a single node.

This is the default v1 plan. It is sufficient, well-understood, validated in production Clojure for 17+ years, and removes one of the largest schedule risks from Phase 1.

**Deferred to v2+**: Relaxed radix balancing (RRB, Bagwell-Rompf 2011) for better `concat` / `subvec` / slice behavior. If added later, it should preserve the language-level vector contract and remain an implementation upgrade rather than a semantic change. `concat` and `subvec` in v1 degrade to O(n) copy in the worst case — exactly as in Clojure.

### 9.3 List — immutable cons

- Classic singly-linked immutable list.
- Primarily for the reader/macros; user code is expected to prefer vectors.
- `first`/`rest`/`cons` are O(1).

### 9.4 Transients

- `transient` produces a mutable wrapper carrying:
  - `owner-token: u64` — isolate-local unique identifier
  - `frozen: bool`
  - inner structure (may share nodes with source)
- Operations on a transient verify `owner-token` matches the current isolate's active token and `frozen = false`.
- `persistent!` flips `frozen = true`, returns the underlying persistent value, and invalidates the transient.
- Using a transient after `persistent!` or from a wrong owner throws `:transient-error`.

Implementation note: the "arena" is an internal allocator detail; the **semantic** model is the ownership token. In v1 (single-threaded), owner-token is cheap to check.

### 9.5 Specialized homogeneous vectors

- `byte-vector`, `int32-vector`, `int64-vector`, `float32-vector`, `float64-vector`.
- Backing is a plain Zig slice in the heap object.
- SIMD-accelerated kernels: `vmap`, `vreduce-sum`, `vdot`, `vfilter-into`, etc.
- These are **separate kinds** from `persistent-vector`; conversions are explicit.

### 9.6 Complexity guarantees

| Op | Persistent map/set | Persistent vector |
|---|---|---|
| Lookup | O(log₃₂ N) | O(log₃₂ N) |
| Insert | O(log₃₂ N) | O(1) amortized (conj), O(log N) (assoc) |
| Delete | O(log₃₂ N) | O(log N) (pop O(1)) |
| Iterate all | O(N) | O(N) |
| Count | O(1) | O(1) |

All collection types cache size and hash on their root node.

### 9.7 Storage-aware variants — explicitly deferred

Making the HAMT mmap-native, page-aligned, and zero-copy over emdb is explicitly a **post-v1 research direction**. v1 persists collections by serializing to a blob (§15.4). This is not where we get clever.

---

## 10. Memory Management

### 10.1 The chosen strategy

**Precise, non-moving, stop-the-world mark-sweep tracing GC** for the runtime heap. **Bump-allocated arenas** for compile-time / macro-expansion intermediates.

No reference counting. No cycle detection. No hybrid.

### 10.2 Why tracing, not RC

- Closures, vars, function objects, namespaces, and especially **captured upvalue chains** form cycles in practice.
- RC on persistent collection nodes is deceptively expensive: every `assoc` bumps/decs many counters along the copied path.
- Precise root enumeration is feasible because the VM is frame/slot-based and we control heap object layout.
- Non-moving simplifies interaction with intern tables, emdb-backed byte slices, and native handles.
- Single-threaded v1 makes STW trivially correct.

### 10.3 Why mark-sweep before generational

- Smaller blast radius if the collector has bugs.
- The code is small enough to audit.
- Throwing away the collector and installing a generational one later is an isolated refactor.
- Without multi-threading, there are no write barriers to worry about.

### 10.4 Allocator

- Per-isolate heap arena backed by a segmented free-list allocator over `std.heap.ArenaAllocator`-shaped page pools.
- Each allocation returns a 16-byte-aligned pointer; heap headers include kind and mark bits.
- Large objects (>4 KiB) allocated directly from OS pages.

### 10.5 Roots

GC roots are enumerated precisely from:

1. The currently executing VM frames (slot pools, upvalue arrays, operand stack if any).
2. The isolate's var table (namespace → symbol → Var).
3. The intern tables (symbol, keyword, optional string).
4. The dynamic-binding stack.
5. Pinned objects: open transactions, open files, durable-ref handles with active reads.
6. The REPL's history buffer (if running interactively).

### 10.6 GC trigger

- Allocation-threshold-based (N bytes since last collection).
- Explicit `(System/gc)` for debugging.
- Never triggered implicitly during transaction commit or codec operations (to keep those predictable).

### 10.7 Arena allocation

Compile-time allocations — parsed Forms, macro-expansion intermediates, compiler IR — live in a scoped arena and are freed en masse when compilation completes. Runtime heap never touches these unless explicitly lifted (via `quote` of a literal, which performs a deep-copy into the runtime heap).

---

## 11. Compiler Pipeline

### 11.1 End-to-end flow

```
source.nx  (.nx file or REPL line)
   │
   ▼  [nexus-generated parser]
Sexp tree
   │
   ▼  [reader: wrap + attach origin/meta]
Form tree
   │
   ▼  [macroexpand: until no top-level macro symbol]
Expanded Form tree
   │
   ▼  [resolve: symbols → locals | vars | special forms, with errors on unbound]
Resolved AST
   │
   ▼  [analyze: closure capture, tail positions, constant folding, literal lifting]
IR (typed, SSA-lite, with slot assignments)
   │
   ▼  [codegen: per-function bytecode + per-fn literal/var tables]
Bytecode module
   │
   ▼  [link: into current namespace, attach to Var roots, optionally persist .no object file]
Loaded routine
```

### 11.2 Stage responsibilities

Stage boundaries are **strict**. A fresh implementation session must not let work drift across stages. Appendix C §28.4 is the authoritative ownership table; summarized here:

1. **Parser** (generated from `nexis.grammar`): source → raw `Sexp` tree with `.src` spans. Pure lexer + LALR(1). No semantic logic.
2. **Reader / normalizer** (`src/reader.zig`): raw `Sexp` → canonical `Form` tree (Appendix C §28.2). Attaches origin + user metadata. Normalizes metadata sugar (`^:kw` → `{:kw true}`, merges multiple metas). Lowers `#(...)` to `(#%anon-fn body)`. Emits `(syntax-quote f)` markers *without* expansion. Discards `#_` forms. Rejects duplicate statically-detectable literal map/set keys, odd map arity, nested anon-fn, bare unquote outside syntax-quote.
3. **Macroexpander** (`src/macroexpand.zig`): canonical `Form` → expanded `Form`. Looks up macros in the current namespace's Var table. **Expands `syntax-quote` forms** (auto-qualification, auto-gensym, unquote/splice handling) as an early sub-pass. **Resolves `(#%anon-fn body)`** to `(fn* [%1 %2 ...] body)` by scanning for positional-arg symbols. Expands user macros outermost-first, to fixpoint, with `&form` and `&env` injected. Recursion limit enforced.
4. **Resolver** (`src/resolve.zig`): expanded `Form` → `Resolved` AST. Binds each symbol reference to one of: local slot, upvalue, Var handle, special form, or error (unbound). Detects shadowing. Resolution order: **special form → lexical local (let/fn/loop binding) → namespace-qualified → alias-qualified → current-namespace mapping**.
5. **Analyzer** (`src/analyze.zig`): `Resolved` → `IR`. Assigns slots, identifies closures/upvalues, marks tail positions, folds constants, lifts literals to the pool.
6. **Codegen** (`src/compile.zig`): `IR` → bytecode. Emits 64-bit instructions, per-function literal/var tables, source maps.
7. **Linker** (`src/loader.zig`): attaches compiled function to a Var, makes it callable, optionally caches an on-disk `.nx.o` file.

### 11.3 Tail calls — the contract

- `(recur args)` is **guaranteed** constant-space. Compiles to: evaluate args into target slots, unconditional jump to entry label. Works inside `loop` or as the tail of the nearest enclosing `fn` arity.
- **General tail positions** emit `tailcall` when:
  - The call is in tail position of a function (not inside `try`/`catch`/`finally`/binding/with-tx with pending unwind).
  - The frame can be replaced (no dynamic bindings to restore beyond the callee's control).
- Otherwise emit ordinary `call` + `return`.
- Tail calls are **not semantically guaranteed** in arbitrary contexts — only `recur` is. The compiler will document which calls were elided via a `--emit-tailcall-report` flag.

### 11.4 Literal lifting and constant pools

- Per-routine literal pool (L#): strings, numbers, collection literals that cannot fit as inline immediates.
- Shared constant pool (C#): common values — `nil`, `true`, `false`, empty map/set/vector, small-integer cache (-128..127), common keywords.
- Interned keyword/symbol references (K#, S#) go through the intern table.
- Collection literals are **materialized at compile time** and placed in the literal pool when fully static; otherwise compiled as construction code.

### 11.5 Error reporting

- Every error carries a `SrcSpan` resolved from the Form. For errors inside macro-expanded code, the error reports both the *expansion site* and the *macro's origin*.
- Resolver errors: unbound symbol, wrong arity, duplicate binding, invalid destructuring.
- Analyzer errors: `recur` outside tail position, `set!` on non-settable, `catch` without `try`.
- All compiler errors use a stable error-kind taxonomy (`:unresolved-symbol`, `:arity-mismatch`, etc.) for tooling integration.

---

## 12. Bytecode & ISA

### 12.1 Physical format

**Reused wholesale from em.** 64-bit fixed-width instructions, optional 20-bit extension instruction for overflow. Same dispatcher shape, same tail-call optimization, same disassembler architecture.

- Primary instruction: `[kind:4][group:6][variant:6][opA:4+12][opB:4+12][opC:4+12]` = 64 bits.
- Extension instruction: `[kind:4][extA:20][extB:20][extC:20]` when any operand exceeds 12-bit range. Reused from em.

### 12.2 Operand kinds — nexis taxonomy

Where em used 8 kinds (CVLSEPJG) shaped by MUMPS semantics, nexis commits to a simpler design: **4 kinds dominate the hot dispatch path, and 3 more live in context-bound opcodes where they never compete with the hot four.** This directly reduces branch-predictor pressure on the critical path.

#### The 4 hot-path kinds (dispatched together in math/cmp/mov/coll/call)

The kind numbers are assigned by **hot-path frequency**, so the most common kind falls in case 0 and any jump-table dispatch puts the predicted branch first:

| Kind # | Letter | Name | Description |
|---|---|---|---|
| 0 | `s` | **slot** | Frame-local slot — the inner-loop workhorse (every local, every temporary) |
| 1 | `c` | **constant** | Constant pool entry (per-routine + shared-pool merged; high bit in index distinguishes) |
| 2 | `v` | **var** | Namespace-indirected `Var` handle (global function calls, var loads) |
| 3 | `u` | **upvalue** | Captured upvalue in the current closure |

**Mnemonic: SCVU** — same as the encoding order, so there's nothing extra to remember. The four letters are each unambiguous in VM vocabulary:

- `s` for **slot** is the universal term across Lua, CPython, V8, the JVM.
- `c` for **constant** is the universal term everywhere outside Lua (Lua uses `k` only because its bytecode reserves A/B/C for operand positions — a constraint we don't share).
- `v` for **var** maps directly to Clojure's *Var* concept, which is the one nexis-runtime notion a developer would naturally call a "variable."
- `u` for **upvalue** is the Lua tradition, well-established in the broader VM literature.

When an opcode's operand is guaranteed one of only two of these (e.g. `math:add` takes slot or constant), the kind field is effectively a 1-bit branch — branch-predictor-friendly and often compiled to predicated code.

#### The 3 context-local kinds (never dispatched alongside the hot four)

| Kind # | Letter | Name | Description |
|---|---|---|---|
| 4 | `i` | intern | Interned symbol/keyword id (global intern table); sub-bit distinguishes keyword vs symbol |
| 5 | `j` | jump | Bytecode offset (only appears in jump instructions — no competition) |
| 6 | `e` | durable | Durable-ref literal (only appears in `tx:*` opcodes — no competition) |

Each of these lives in a narrow context where the opcode *knows* which kind of operand it has, so no runtime dispatch on kind is needed. They cost zero branch-predictor pressure on the hot path.

#### How context-local kinds actually work

The distinction between hot-path (SCVU) and context-local (IJE) is the whole point of the split. The physical ISA stays completely uniform — every operand slot is 4 kind bits + 12 index bits — but who reads those kind bits differs.

**One-sentence rule:**

> **I, J, and E are encoding labels for operands whose kind the opcode already fixes by its own definition; S, C, V, and U are the four kinds the polymorphic opcodes actually dispatch on.**

The **hot-path opcodes** (math/cmp/mov/coll/call) genuinely accept any of S/C/V/U for their operands, so the handler reads the kind field at runtime and dispatches:

```zig
switch (kind) {
    0 => frame.slots[idx],         // S
    1 => routine.consts[idx],      // C
    2 => loadVar(idx),             // V
    3 => frame.upvals[idx],        // U
}
```

That's a 2-bit branch (values 0–3), very predictable. Handlers for these opcodes pay this cost once per operand.

The **context-local opcodes** are defined such that each operand position has *exactly one possible kind*. Their handlers don't read the kind field at all — they already know. The 4 kind bits are still written by the assembler and read by the disassembler for clarity, but at runtime they're ignored (or asserted in debug builds).

##### Concrete: `jump:jmp`

```zig
fn execJmpJmp(vm: *VM) void {
    const inst = vm.currentInst();
    // No kind dispatch. Operand A is ALWAYS a jump target by definition of this opcode.
    vm.pc = inst.operandA().index;
    @call(.always_tail, dispatch, .{vm});
}
```

##### Concrete: `jump:if-eq` — mixed case

Operand A is always J. Operands B and C are hot-path (typically S or C). So *this* handler skips dispatch on A but does dispatch on B and C:

```zig
fn execJumpIfEq(vm: *VM) void {
    const inst = vm.currentInst();
    const target = inst.operandA().index;          // A is J — no dispatch
    const valB = resolveHot(vm, inst.operandB());  // B is S/C/V/U — dispatch
    const valC = resolveHot(vm, inst.operandC());  // C is S/C/V/U — dispatch
    if (valB.eq(valC)) vm.pc = target;
    @call(.always_tail, dispatch, .{vm});
}
```

##### Concrete: loading an interned keyword with `i` operands

When the compiler sees a keyword literal that needs to be materialized as a runtime Value (e.g., passing `:foo` as an argument), it emits a specialized opcode:

```
mov:load-keyword  s:3  i:7     ; s:3 = the keyword with intern id 7 (e.g. :foo)
```

The handler knows operand B is an intern id; no dispatch needed there. The generic `mov:move` handles hot-path operands (S/C/V/U); `mov:load-keyword` is the specialization for intern-id operands. **Two opcodes, two handlers, neither pays the other's cost.**

##### Concrete: durable-ref literal with `e` operands

When the compiler can resolve a durable ref at link time, it populates the routine's E# table and emits the `-lit` variant:

```
tx:ref-deref-lit  s:0  e:3     ; s:0 = @(durable-ref literal #3 from routine table)
```

For runtime-computed refs (the common case — `(db/ref conn :users uid)` building one dynamically), the generic `tx:ref-deref` is emitted, whose B operand is hot-path.

##### How the compiler decides

Mental model for emitting an operand: **what kinds could this realistically be?**

- "Could be any of the four" → emit with hot-path kind (S/C/V/U), use generic opcode.
- "Always a jump target" → emit J, pick the jump-family opcode.
- "Always an intern id" → emit I, pick the `-kw` / `-sym` / `-intern` variant opcode.
- "Always a compile-time-known durable ref" → emit E, pick the `-lit` variant opcode.

So I/J/E are not alternatives to S/C/V/U — they are **how certain specialized opcodes encode operands they already know the type of**. The specialization lives in the *opcode*; the kind field is just for encoding consistency and disassembler clarity.

##### Worked example

Source: `(if (= x 0) (println "zero") (println x))` — `x` in slot 1, `"zero"` in constant 5.

```
0000  jump:if-ne        j:0020  s:1    c:0       ; if x != 0, jump past then-branch
0008  io:println-lit            c:5    -         ; println "zero"   (specialized: operand is always C)
0010  jump:jmp          j:0028  -      -         ; skip else-branch
0018  io:println                s:1    -         ; println x        (generic: operand is hot-path)
0028  ...
```

Four opcodes, four handlers, **two kind dispatches in total** — only at the two hot-path operand positions. The J operands at 0000 and 0010, and the C operand inside `io:println-lit` at 0008, all skip dispatch entirely because the opcode already fixes their kind.

##### Why this matters — three concrete wins

1. **Hot-path dispatcher stays a clean 2-bit switch.** The performance-critical operand resolution for math/cmp/mov/coll/call only ever sees values 0–3. The branch predictor loves this.
2. **Specialized opcodes have zero dispatch overhead on their context-local operands.** `jump:jmp`, `tx:ref-deref-lit`, and `coll:map-get-kw` pay nothing to know what their fixed-kind operands are.
3. **The encoding is still uniform.** Every instruction is 64 bits with three 16-bit operand slots. The disassembler, assembler, object-file format, and validator all work identically. The only thing that varies is whether a particular handler reads the kind field or ignores it.

#### Reserved slots

| Kind | Purpose |
|---|---|
| 7–14 | Reserved — future typed-vector slots, foreign handles, protocol method indices, etc. |
| 15 | Unused — `FFFF` sentinel for missing operand |

#### LuaJIT-style operand-specialized opcodes (reserved for Phase 6)

Even the 1-bit kind branch on hot math/cmp ops can be eliminated by **baking operand kinds into the opcode itself.** LuaJIT does this: instead of one `ADD` opcode, it has `ADDVV`, `ADDVN`, `ADDNV`, each taking fixed-kind operands with zero runtime dispatch.

We reserve variant slots in groups 0–3 (jump/cmp/math/mov) for specialized forms like:

- `math:add-ss`, `math:add-sc`, `math:add-cs`  (slot/slot, slot/constant, constant/slot)
- `cmp:lt-ss`, `cmp:lt-sc`
- `jump:if-eq-ss`, `jump:if-eq-sc`
- `mov:load-from-c`, `mov:load-from-s`, `mov:load-from-v`

This is **not** a v1 feature. The ISA reserves the variant space so these can be added in Phase 6 as a pure optimization pass without any ABI break. Expected speedup on numeric hot loops: ~10–30%, at the cost of a few dozen extra opcode slots (out of 4,096). Essentially free real estate.

### 12.3 Opcode groups (v1)

64 groups available; v1 uses ~14. Each group has 64 variant slots.

| # | Group | Purpose | Notable variants |
|---|---|---|---|
| 0 | `jump` | Unconditional + conditional branches | `jmp`, `t`, `f`, `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `nil?`, `kind?` |
| 1 | `cmp` | Compare, result to A | `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `identical`, `type` |
| 2 | `math` | Integer + float arithmetic | `add`, `sub`, `mul`, `div`, `quot`, `rem`, `neg`, `abs`, `inc`, `dec`, `bit-and`, `bit-or`, `bit-xor`, `bit-not`, `shl`, `shr` |
| 3 | `mov` | Data movement | `move`, `const`, `load-lit`, `load-const`, `load-nil`, `load-true`, `load-false`, `load-fixnum-inline` |
| 4 | `call` | Function invocation | `call`, `tailcall`, `invoke-var`, `apply`, `return`, `return-nil` |
| 5 | `closure` | Closure creation | `make-closure`, `load-upvalue`, `store-upvalue` |
| 6 | `var` | Var operations | `load-var`, `store-var` (root rebind), `push-dynamic`, `pop-dynamic`, `load-dynamic` |
| 7 | `coll` | Collection primitives | `map-get`, `map-assoc`, `map-dissoc`, `vec-nth`, `vec-assoc`, `vec-conj`, `set-contains`, `set-conj`, `set-disj`, `count`, `seq`, `first`, `rest`, `cons`, `empty?`, `make-map-n`, `make-vec-n`, `make-set-n`, `make-list-n` |
| 8 | `transient` | Transient lifecycle | `transient`, `persistent`, `t-assoc`, `t-dissoc`, `t-conj`, `t-pop` |
| 9 | `hash` | Hashing and equality kernels | `hash`, `hasheq-combine`, `str-hash`, `coll-hash` |
| 10 | `tx` | Transaction boundaries and durable ops | `tx-read-begin`, `tx-write-begin`, `tx-commit`, `tx-abort`, `ref-deref`, `ref-put`, `ref-delete`, `ref-key-hash`, `ref-new` |
| 11 | `ctrl` | Control flow meta | `throw`, `try-enter`, `try-exit`, `finally-enter`, `finally-exit`, `halt`, `gc-hint` |
| 12 | `io` | Minimal I/O | `print`, `println`, `read-line`, `tap` |
| 13 | `simd` | Typed-vector kernels (optional in v1) | `vmap`, `vreduce-sum`, `vdot`, `vfilter-count`, `vload`, `vstore` |

Remaining groups 14–63 are reserved for: protocols (future), typed records, schema ops, ffi, distributed message passing, etc.

### 12.4 RISC discipline

Following em's lesson: **complex polymorphic operations go through a narrow waist.**

- `math`, `cmp`, `mov` operate on simple operands (slots, constants, literals).
- `coll` is where kind-dispatched collection polymorphism lives. Every collection op resolves `Value.tag.kind` once, then calls an internal ops table for heap kinds. Nil fast paths are inlined.
- `tx` is the only place durable refs get special handling.

This keeps the VM dispatcher clean and the hot path tight.

### 12.5 Dispatcher

Reused from em:

```zig
fn dispatch(vm: *VM) void {
    const inst = vm.code[vm.pc];
    vm.pc += 1;
    const h = handlers[inst.group()][inst.variant()];
    @call(.always_tail, h, .{vm});
}
```

Two-level switch fallback where tail calls are not reliable.

### 12.6 Object file format

Reuse em's `.o` (renamed `.nx.o` here) with a new magic number. Per-function payload:

- Bytecode array
- Constant pool (C#) — per-routine and shared-pool entries with a flag bit in the index
- Var handle table (V#) — resolved lazily at link time
- Durable-ref literal table (E#) — resolved to `{store-id, tree-id, key}` at link time
- Intern table snapshot (I#) — symbols/keywords referenced by this routine
- Source map: PC → `SrcSpan`
- Metadata: arities, name, namespace, docstring (optional)

---

## 13. Runtime

### 13.1 VM shape

Adapted directly from em:

- Per-isolate `Runtime` struct holding: namespaces, intern tables, heap, open transactions, dynamic binding stack, current exception context.
- Per-call `Frame`: slot array (size = function's declared slot count), upvalue array, routine reference, PC, return-address.
- Tail-call dispatched interpreter over the 4,096-opcode table.

### 13.2 Function and closure

- A `function` value holds: pointer to bytecode, arity info, upvalue template, metadata.
- A `closure` is a function value with its upvalues bound. In v1 we do not distinguish function-without-upvalues from closure-with-upvalues at the Value level; both are kind `function`.

### 13.3 Var machinery

- `Var` heap object: `{ns, sym, root, dynamic?, macro?, const?, meta, revision}`.
- **Unbound marker**: a reserved singleton `#unbound` that is not `nil`. Accessing an unbound var throws `:unbound-var`.
- **Dynamic binding**: shallow binding stack on the isolate. `push-dynamic` saves old binding; `pop-dynamic` restores. Dynamic vars must be declared `^:dynamic` at `def`.
- **REPL redefinition**: `(def foo ...)` mutates an existing `Var`'s `root` in place. **Global function references are invoked via Var indirection by default**, so new calls see the new root immediately after redefinition. **Lexical locals and captured upvalues compile directly** — no Var indirection — so their values are frozen at capture time and are not affected by later redefinitions. This gives REPL redefinition of globals without paying indirection cost on every closure-local variable access.
- **Namespace reload** preserves Var identity for surviving names; removed names' Vars persist but are unbound; new names get new Vars.
- **Revision counter** bumps on every root rebind, to enable future inline-cache invalidation.

### 13.4 Dynamic binding

- Only `^:dynamic` vars can be rebound via `binding`.
- `(binding [*out* some-stream] ...)` compiles to `push-dynamic *out* some-stream` + body + `pop-dynamic *out*`.
- Lookup of a dynamic var walks the binding stack first, then falls back to the Var's root.

### 13.5 Exception and finally

- `throw` unwinds until a matching `catch` is found. Along the way, `finally` handlers execute and open transactions abort.
- Source-mapped stack traces are built by walking frames and resolving `PC → SrcSpan` from the routine's source map.

### 13.6 REPL

- Line editing and history (adapt em's REPL).
- Each line is read → form-wrapped → macroexpanded → compiled → executed.
- `*1 *2 *3` hold the last three results.
- `*e` holds the last exception.
- Commands (prefix `/` to disambiguate from symbols): `/help`, `/doc`, `/ns`, `/reload`, `/disasm`, `/macroexpand`, `/time`, `/tap-listen`, `/quit`.
- Tap: `(tap> x)` sends `x` to any attached tap listener (a REPL-connected inspector).

---

## 14. Macros & Namespaces

### 14.1 Macros

- A `Var` with `macro: true` is a macro. Its value must be a function that conceptually receives **`(&form, &env, user-args...)`** and returns a `Form`. This matches Clojure's macro calling convention and is the minimum power needed for scope-aware expansion.
- `&form` is the full invocation form being expanded (with source-span metadata intact). `&env` is the lexical environment at the expansion site, exposed in v1 as a deliberately shallow map of `symbol → LocalBinding`.
- `(defmacro name [args] body)` is sugar for defining a macro-valued `Var`; the compiler injects `&form` and `&env` as invisible leading arguments at expansion time.
- During macroexpansion, the compiler resolves head-position symbols to macro Vars and invokes them **at compile time** with the invocation form, lexical environment, and user arguments.
- Macros run in a controlled compile-time environment: they may call functions from already-loaded namespaces, inspect `&form`, and consult the minimal `&env` view. v1 deliberately keeps `&env` small; it may be extended later without changing the core model.
- **Macros do not run at runtime.** After macroexpansion, no reference to the macro Var survives in the compiled bytecode.

### 14.2 Syntax-quote

**Stage ownership**: the reader (see §11.2 and Appendix C §28.4) emits a `(syntax-quote form)` marker without expansion. Expansion happens in the **macroexpander** as a distinct early sub-pass before ordinary macro fixpoint. This keeps the reader stateless and puts all symbol resolution in the stage that already knows the current namespace.

Inside `` `form `` (processed by the macroexpander):

- Lists become `(seq (concat (list ...) (list ...)))` expressions.
- Vectors become `(apply vector (seq (concat ...)))`.
- Maps become `(apply hash-map (seq (concat ...)))` (error on odd count).
- Sets become `(apply hash-set (seq (concat ...)))`.
- Unqualified symbols are **auto-qualified** via the current namespace's lookup rules (shadowing special forms).
- `~x` unquotes; `~@x` unquote-splices (inside list positions).
- Symbols ending in `#` (e.g. `x#`) are **auto-gensyms**: within one syntax-quote scope, every occurrence of `x#` resolves to the same fresh symbol; across scopes, they are distinct. This eliminates the most common macro hygiene failure without full Scheme-style hygiene.
- Keywords, numbers, strings, chars are self-evaluating and kept as-is.

**Macroexpand-1 vs macroexpand-fixpoint**: the REPL exposes both `/macroexpand-1 'form` (one step) and `/macroexpand 'form` (to fixpoint) for tooling. A hard recursion limit (e.g. 256 nested expansions) throws `:macro-expansion-runaway` to prevent infinite macros.

### 14.3 Namespaces

A namespace is a heap object:

```zig
pub const Namespace = struct {
    name: Symbol,
    mappings: PersistentMap,   // sym → Var (both local and imported)
    aliases: PersistentMap,    // alias-sym → Namespace
    refers: PersistentMap,     // which vars are referred from elsewhere
    meta: ?*PersistentMap,
};
```

- `(ns my.app (:require [other.ns :as o] [util :refer [foo bar]]))` — declarative namespace form.
- Symbol resolution:
  1. If fully qualified (`ns/sym`): look up namespace, then find var.
  2. If alias-qualified (`o/sym`): look up alias → namespace → var.
  3. If unqualified: lookup in current namespace's mappings (which include refers).
- The REPL has an implicit namespace `user` at startup.

### 14.4 Load semantics

- `(load "path/to/file.nx")` reads, compiles, and installs forms into the current namespace.
- `(require 'some.ns)` locates the namespace's source file, loads it if not already loaded, and interns the namespace object.
- Load order is topological; cycles in `require` throw `:namespace-cycle`.

---

## 15. Durable Identities (emdb Integration)

The heart of the nexis differentiator. Defined with care because a wrong semantic choice here corrupts everything above it.

### 15.1 Connection model

```clojure
(def conn (db/open "app.edb" {:max-map-size 1gb}))
```

- A **connection** is a heap object wrapping an `emdb.Env`.
- Multiple connections to different files are allowed.
- A connection has a stable `store-id: u128` derived from the file UUID written in emdb's meta page.

### 15.2 Durable-ref construction and shape

```clojure
(def alice (db/ref conn :users "alice"))
```

- A `durable-ref` value has three components:
  - `store-id: u128` — identifies the database file/connection.
  - `tree-id: Keyword` — names the emdb sub-database (each keyword maps to one named B+ tree).
  - `key-bytes: []const u8` — the encoded key within that tree.
- The `key-bytes` are produced by encoding the second-and-subsequent arguments through the emdb Key encoder (reused from em).
- `(= r1 r2)` iff all three components match byte-for-byte.
- `(hash r)` derived from the triple, **independent of current stored value**.

### 15.3 Transactions — explicitly lexical

```clojure
(with-tx [tx conn]                  ;; write transaction
  (db/put! tx alice {:age 31})
  (db/alter! tx bob inc-age))

(with-read-tx [tx conn]             ;; read transaction
  (let [a @alice-via-tx ...]))
```

- `with-tx` opens a **write transaction**; commits on normal exit, aborts on exception.
- `with-read-tx` opens a **read snapshot**; always aborts on exit (reads don't commit).
- Outside any `with-*-tx`, individual `@durable-ref` operations open their own **ephemeral read transactions** — one per deref.
- **Consistency across multiple reads** requires an explicit `with-read-tx`. Users who forget and observe skewed data — we chose not to protect them with ambient magic. This is by design.

### 15.4 Deref semantics

- `@durable-ref` (or `(deref durable-ref)`):
  1. If the current dynamic context has an active read or write transaction on the matching connection, use it.
  2. Otherwise, open an ephemeral read transaction, read, abort.
  3. Missing key → `nil`.
  4. Value decoded from stored bytes via the durable codec.
- `(db/present? r)` → `true`/`false` without materializing the value.
- `(db/deref-or r default)` → returns `default` when missing instead of `nil`.

### 15.5 Put and alter

- `(db/put! tx r v)` — only inside `with-tx`. Encodes `v` through the codec and writes `(tree-id, key-bytes) → encoded-v`.
- `(db/alter! tx r f & args)` — reads current value (or `nil`), computes `(apply f current args)`, writes result. Must be inside `with-tx`.
- `(db/delete! tx r)` — removes the key.
- `(db/put! ...)` and friends **outside** `with-tx`: error, not implicit-tx. This is a deliberate contrast to some Clojure-atom conventions; nexis requires transactions to be explicit.

### 15.6 Codec

Self-describing tagged wire format:

```
[kind:u8] [flags:u8] [len:varint] [payload...]
```

- Kinds match `Value.tag.kind` where applicable; heap sub-kinds encoded in the first byte of payload.
- Integers: varint-encoded.
- Floats: IEEE 754 big-endian.
- Strings: UTF-8 bytes, length-prefixed.
- Keywords/symbols: textual form (intern on decode) — never intern ids on the wire.
- Collections: length-prefixed, recursive.
- Durable refs: the identity triple, so a ref stored in a map round-trips cleanly.
- **Round-trip invariant**: `(= v (db/decode (db/encode v)))` for every v1 value kind. Heavily fuzzed (§20).

### 15.7 Historical reads (as-of) — promoted to v1

emdb's copy-on-write + MVCC already provides everything we need for `as-of` reads. A read transaction in emdb *is* a snapshot pinned to a specific commit generation, held alive as long as the transaction is open. We expose this as a first-class language feature in v1:

- **`(db/snapshot conn) → snapshot`** — captures the current commit generation. Cheap (a tx-id + connection reference, roughly 32 bytes). Snapshots are ordinary values: compare, put in maps, pass to functions.
- **`(with-read-tx-at [tx conn snap] ...)`** — opens a read transaction pinned to the given snapshot. All `deref` operations inside see exactly the state that existed when `snap` was captured, regardless of subsequent writes.
- **`(db/as-of conn snap) → db-value`** — returns a *database-as-value* bound to that snapshot. A `db-value` is the ambient snapshot context: `(deref ref :using db-value)` or `(with-db db-value ...)` reads through it. Borrowed directly from Datomic's `(d/as-of db #inst ...)`.
- **Ephemeral snapshots** — every `with-read-tx` implicitly captures a snapshot; you can name it and keep it alive past the tx's scope with `(db/pin-snapshot tx)`.

**Caveats in v1:** snapshots consume disk space — emdb cannot reclaim pages that any pinned snapshot still references. Long-held snapshots cause the file to grow. We document this as the single cost users pay for time travel. Phase 5 tooling includes `(db/snapshot-stats conn)` showing pinned snapshots and their page cost.

**Why we promoted this:** when your storage engine already implements MVCC correctly, exposing time travel is a few hundred lines of library code, not a research project. Leaving it out of v1 would be self-imposed amnesia about what the substrate can do.

**What is still deferred to v2:** historical range queries (`(db/history ref start-snap end-snap)` returning a sequence of `[snap, value]` pairs), because that requires walking emdb's free list of page generations — straightforward but not needed for the core value proposition.

### 15.8 Iterators over trees

- `(db/cursor tx tree-id)` → cursor value; `(c/seek c k)`, `(c/next c)`, `(c/key c)`, `(c/val c)`.
- `(db/reduce-tree tx tree-id f init)` — server-side-style reduction with the cursor.
- `(db/scan tx tree-id start end)` — bounded range as a lazy sequence (one of the few lazy things in v1, and only here because it is the right abstraction for cursors).

### 15.9 What durable refs are NOT

- Not Clojure refs (no STM).
- Not Clojure atoms (no in-memory CAS retry loop).
- Not Datomic entities (no separate indexing beyond emdb's key order; no query engine in v1).
- Not ORM rows.

They are **transactional identity cells backed by a memory-mapped B+ tree**. Call them by their name.

### 15.10 Serializability matrix (v1) — what the codec supports

**Non-negotiable scoping rule.** The codec is the single gateway between runtime Values and durable bytes. This matrix defines what v1 supports. Extending it requires a PLAN.md amendment; silently broadening it is how the language turns into a "serialize-anything" tar pit.

#### Serializable in v1

| Value kind | Notes |
|---|---|
| `nil` | single sentinel byte |
| `bool` | single byte |
| `char` | UTF-8-encoded Unicode scalar |
| `fixnum` | zig-zag varint |
| `bignum` | length-prefixed big-endian byte sequence |
| `float` (f64) | IEEE 754 big-endian, canonical NaN |
| `string` | UTF-8 bytes, length-prefixed |
| `keyword`, `symbol` | **textual form**, not intern id; receiver re-interns on decode |
| `list`, `vector`, `map`, `set` | length-prefixed, recursive |
| `byte-vector` | raw bytes, length-prefixed |
| `typed-vector` | element type tag + little-endian element bytes |
| `durable-ref` | identity triple `{store-id, tree-id, key-bytes}` — does **not** serialize the dereferenced value |

#### Not serializable in v1

| Value kind | Reason |
|---|---|
| `function` / closure | Code, upvalues, and any captured VM state are process-local. Serializing them would pull in bytecode, the intern table, and Var identities. Out of scope. |
| `var` | Identity and mutation machinery are process-local by definition. Serialize the *root value* instead if needed. |
| `transient` | Mutable by definition. Only `persistent!`-ed results cross the codec. |
| `namespace` | Process-local binding table. |
| `tx handle` / `emdb.Env` connection | Handles to open OS resources. |
| `error` | Exception values include stack traces with process-local frame references. Serializable subset TBD; v1 rejects. |
| Any handle to open files, devices, cursors | OS resources. |
| Future: `record` (currently deferred) | Undefined in v1. See §24. |

#### Attempting to serialize a non-serializable value

The codec throws `:unserializable {:kind :function :reason "functions are not serializable in v1"}`. The error kind is stable so tooling can match on it. No silent truncation, no stub placeholders, no lossy round-trips.

#### Round-trip invariant (formal)

For every value `v` whose kind is in the "Serializable" table above:

- `(= v (codec/decode (codec/encode v)))` — value equality preserved
- `(= (hash v) (hash (codec/decode (codec/encode v))))` — hash preserved
- `(= v (codec/decode-bytes (codec/encode-to-bytes v)))` — byte-level round-trip stable

This is the Phase 1 gate property test #5, exercised on 10k+ randomized values.

### 15.11 The "Nextomic" opportunity — a Datomic-class database inside nexis

> **Authoritative architecture for Nextomic now lives in
> [`docs/NEXTOMIC.md`](docs/NEXTOMIC.md).** This section remains the
> opportunity statement and the v1-side commitments that do not
> preclude the Nextomic path. Anything implementation-shaped
> (storage layout, key encodings, Relation type, query pipeline,
> schema, risks) belongs in `docs/NEXTOMIC.md` and is binding once
> Nextomic is actually scoped as a project.

**Beyond v1, the same substrate that powers durable refs could host a full Datomic-class database as a nexis library.** This is not a v1 deliverable, but it's worth naming because it shapes long-term direction.

#### What Datomic actually is

Datomic is built around five ideas:

1. **Datom model**: `[entity, attribute, value, tx, added?]` 5-tuples. Everything is a fact about an entity, stamped with the transaction that asserted it.
2. **Four indexes**: EAVT (entity-centric), AEVT (by attribute), AVET (for attribute-value lookup with unique/indexed attrs), VAET (reverse references).
3. **Datalog query**: a declarative logic-programming query language. Clauses match patterns over datoms.
4. **Pull syntax**: a declarative tree-shape specifier for retrieving connected entity graphs.
5. **Time is fundamental**: every datom knows its transaction; `as-of`, `since`, and `history` are first-class.

#### Why emdb + nexis is an excellent substrate for this

- **Named trees give us the four indexes for free.** One B+ tree per index. emdb already supports multiple independent B+ trees in a single file. Key encoding handles the ordered composite keys (`e|a|v|tx`, `a|e|v|tx`, etc.) directly.
- **MVCC + CoW gives us time travel natively.** A snapshot is a pinned transaction ID. `as-of`, `since`, and `history` are all variations on range scans over the tx-indexed data.
- **Single-writer model matches Datomic's transactor.** Datomic famously has one transactor that serializes all writes and distributes the log to peers. emdb's single-writer-many-readers is the same shape.
- **Persistent collections make query results natural.** Datalog returns a set of tuple bindings; in nexis, that's a `persistent-set` of `persistent-vector`s. No impedance mismatch.
- **Macros give us the query DSL.** `(d/q '[:find ?e :where [?e :user/name "alice"]] db)` compiles at parse time to a query plan.

#### Precedent that proves it's feasible

The Clojure ecosystem has already validated this path on LMDB-class engines:

- **Datahike** — open-source Datomic-alike, runs on LMDB, in-memory, browser (via persistent data structures), and other backends. ~10k LOC of Clojure. Datalog + pull + time travel.
- **XTDB (formerly Crux)** — bitemporal (valid-time + transaction-time) document-oriented Datalog database. Also runs on LMDB-class engines.
- **Datascript** — in-memory-only Datomic subset. Popular for browser use. Proves that with persistent collections you can build a working Datalog engine in a few thousand LOC.

None of these have emdb's performance profile, pure Zig implementation, or the tightly integrated host language. We have a cleaner starting point.

#### What "Nextomic" would look like as a post-v1 nexis library

A working sketch:

```clojure
(require '[nexis.nextomic :as d])

(def conn (d/connect "users.ndb"))

(d/transact! conn
  [[:db/add 1 :user/name "alice"]
   [:db/add 1 :user/age  30]
   [:db/add 2 :user/name "bob"]
   [:db/add 2 :user/friend 1]])

(d/q '[:find ?name
       :where [?e :user/name ?name]
              [?e :user/age ?a]
              [(> ?a 25)]]
     (d/db conn))
;; => #{["alice"]}

(d/pull (d/db conn) '[:user/name {:user/friend [:user/name]}] 2)
;; => {:user/name "bob", :user/friend {:user/name "alice"}}

(d/q query (d/as-of (d/db conn) yesterday-snapshot))  ; time travel
```

Implementation estimate (revised in `docs/NEXTOMIC.md` §10 after deeper review):

- **Datom encoding and four indexes + tx-log**: ~1,500 LOC.
- **Schema + unique/indexed/ref attribute handling**: ~800 LOC (revised up from 500 — schema machinery is easy to underscope).
- **Internal `Relation` type + column kernels**: ~600 LOC (new line item — see §15.11.1 below).
- **Datalog query compiler (macro → IR)**: ~500 LOC.
- **Runtime planner (IR → plan)**: ~800 LOC.
- **Executor + cursor drivers**: ~900 LOC.
- **Pull syntax**: ~500 LOC.
- **Temporal operators** (`as-of`, `since`, `history`): ~300 LOC, mostly riding on §15.7.
- **`datom` heap kind + accessors**: ~200 LOC.

**Revised total: ~6.1k LOC of nexis as a library.** Still feasible as a post-v1 side project; could ship as `nexis-nextomic` without changes to the core language, to emdb, or to em.

#### 15.11.1 Frozen-once-scoped architectural decisions

After a two-round peer-AI architectural review (GPT-5.4 via the
`user-ai` MCP, conversation `nextomic-on-nexis-emdb`), six
architectural decisions were identified as the separators between
"serious 2026+-class contender" and "beautiful proof-of-concept."
Full rationale is in [`docs/NEXTOMIC.md`](docs/NEXTOMIC.md) §3;
these become binding in the same way PLAN §23 decisions bind v1,
but only when Nextomic is actually scoped as an active project.

| # | Decision | Short rationale |
|---|---|---|
| NX-1 | **Integer entity ids** (fixnum), NOT durable-refs. Attr ids = `u32` keyword intern ids. Durable-refs stay the `nexis.db` handle type but are NOT Nextomic's entity identity. | Fitting eids into the Value payload is 8 bytes vs ~40; lex-sort is one instruction; entity identity must not encode storage topology. |
| NX-2 | **Internal Relation type** — column-oriented, backed by existing `typed_vector` Value kinds. API results stay persistent-set-of-persistent-vector; the engine does NOT use that representation internally. | Generic persistent collections all the way is correct and slow. This is the single highest-leverage decision Nextomic will make. |
| NX-3 | **Macro → IR → runtime-plan split.** Macro compiles query literal to IR (embedded as a bytecode constant). Runtime planner lowers IR to a plan using current schema + bound inputs. | Macros alone cannot plan (schema and bindings are runtime). Runtime alone pays parse cost per call. The split is roughly 40 / 30 / 30 between the three stages. |
| NX-4 | **tx-in-key filtering for history, NOT emdb snapshot pinning.** Datoms are append-only with `tx` in the key; `as-of T` is a range filter. emdb snapshots are reserved for operational reproducibility, not semantic history. | Pinned snapshots prevent page reclamation; tx-in-key does not. Datomic semantics demand history-as-data, not history-as-page-retention. |
| NX-5 | **`datom` as a new heap Value kind** — five accessors (`.e .a .v .tx .added?`), user-facing projection only. Execution operates on `Relation` columns, not on datom values. Serializes via projection to existing §15.10 kinds; no codec amendment. | Nicer ergonomics and cheaper accessors than vector-of-five-Values, without leaking into the hot execution path. |
| NX-6 | **One named sub-DB per concern** (`:nextomic/txlog`, `:nextomic/eavt`, `:nextomic/aevt`, `:nextomic/avet`, `:nextomic/vaet`, `:nextomic/schema`, `:nextomic/idents`, `:nextomic/sys`). Keys are binary-sortable byte strings; emdb default lex comparator is exactly the needed order. Index values are empty — the key IS the datom. | Atomic multi-index commit falls out of emdb's single meta-page flip. Branch-page prefix compression (G=1/G>1/G<0) compresses composite EAVT keys maximally. |

**Three things `docs/NEXTOMIC.md` explicitly rejects as temptations:**

1. Extending the §15.10 codec matrix for query plans or compiled
   rules. Layer 2 and Layer 3 must not fuse.
2. Adding Nextomic-specific features to emdb. The temptation list
   is captured in [`../emdb/NEXTOMIC.md`](../emdb/NEXTOMIC.md).
3. Falling back to persistent-set-of-persistent-vector as the
   internal relation representation. This is the single
   architectural failure mode that would turn Nextomic into a
   proof-of-concept.

#### Why it matters strategically

If nexis ships with a credible Datomic-class embedded database as a library, the positioning shifts from "a new Lisp" to "a new Lisp that comes with a queryable immutable database." That's a category other languages don't occupy:

- **Clojure + Datomic**: two separate things; you pay for Datomic or install Datahike and wire it up.
- **Racket**, **Janet**, **Fennel**, **Chicken**: no equivalent in the core ecosystem.
- **Common Lisp (SBCL)**: third-party libraries exist but nothing vertically integrated.
- **nexis**: language + VM + storage + durable-ref + (eventual) Datalog, all in one coherent design.

This is the strongest version of the "database-as-value" story. The PLAN does not commit to building Nextomic in v1 — doing so would miss the single-coherent-thing target. We *aim* not to preclude it:

- Durable-ref encoding leaves room for an EAVT representation (tree-id = index-name, key-bytes = composite e-a-v-tx key).
- Snapshot semantics (§15.7) are already the foundation for `as-of`.
- Transactions (§15.3) are already the foundation for the datom-assertion model.
- Persistent collections are the natural return type for query results.

**This is an aspiration, not a guarantee.** As v1 semantics lock in, some choices may prove constraining; we'll revisit each one honestly when the Nextomic library is actually scoped.

**Naming.** "Nextomic" is the working codename; the shipped library would likely have a cleaner name (`nexis.datalog`, `nexis.log`, or similar). But the idea is the thing.

---

## 16. Concurrency & Isolation

### 16.1 v1 decision

**Single process. Single isolate. Single executing thread.** Declared as an affirmative design choice, not a limitation.

Benefits:

- GC: trivial stop-the-world correctness.
- Transients: owner-token check is a single equality compare.
- Dynamic bindings: no thread-local complexity.
- emdb writer lock: uncontested.
- Debugging: linear execution narrative.

### 16.2 What is allowed in v1

- Blocking I/O (files, TCP via stdlib Zig) — the runtime runs to completion of each op.
- Multiple **connections** to different emdb files.
- Multiple **namespaces** and Vars.
- Multiple **open read transactions** (emdb supports this natively; v1 just doesn't execute code concurrently against them).

### 16.3 What is not in v1

- No threads.
- No futures/promises.
- No `core.async`-style channels.
- No parallel `pmap`.
- No multi-isolate message passing (the "Nexus" orchestration concept is a future integration).

### 16.4 Future direction (non-binding)

Multi-isolate version would:

- Each isolate: single-threaded, owns its own heap and intern tables.
- Inter-isolate: message passing with **value copy via codec** (not raw pointer sharing).
- emdb: unchanged — its single-writer multi-reader model composes naturally with isolates.
- Shared immutable durable state is available read-only via zero-copy mmap views.

This is **out of scope** until v1 has shipped and stabilized.

---

## 17. Standard Library Shape

### 17.1 Core (always loaded)

Namespace `nexis.core`, auto-referred in `user` and every `ns` form that does not opt out.

| Category | Symbols |
|---|---|
| Arithmetic | `+`, `-`, `*`, `/`, `quot`, `rem`, `mod`, `inc`, `dec`, `min`, `max`, `abs`, `neg?`, `pos?`, `zero?`, `even?`, `odd?` |
| Comparison | `=`, `not=`, `<`, `<=`, `>`, `>=`, `identical?`, `compare` |
| Logic | `and`, `or`, `not`, `if-not`, `when`, `when-not`, `cond`, `case` |
| Binding | `let`, `if-let`, `when-let`, `letfn` |
| Looping | `loop`, `recur`, `while`, `doseq`, `dotimes` |
| Collections | `count`, `empty`, `empty?`, `seq`, `first`, `rest`, `next`, `last`, `cons`, `conj`, `into`, `nth`, `get`, `get-in`, `assoc`, `assoc-in`, `dissoc`, `update`, `update-in`, `merge`, `select-keys` |
| Map-specific | `keys`, `vals`, `find`, `contains?`, `hash-map`, `sorted-map` (later) |
| Set-specific | `hash-set`, `disj`, `union`, `intersection`, `difference` |
| Vector-specific | `vector`, `vec`, `peek`, `pop`, `subvec` |
| Sequence ops | `map`, `filter`, `remove`, `reduce`, `reductions`, `take`, `drop`, `take-while`, `drop-while`, `partition`, `partition-by`, `concat`, `interleave`, `interpose`, `range`, `repeat`, `iterate`, `reverse`, `sort`, `sort-by`, `group-by`, `frequencies` |
| Strings | `str`, `subs`, `split`, `join`, `upper-case`, `lower-case`, `trim`, `starts-with?`, `ends-with?`, `includes?`, `replace` |
| Predicates | `nil?`, `some?`, `true?`, `false?`, `boolean?`, `number?`, `integer?`, `float?`, `string?`, `keyword?`, `symbol?`, `map?`, `vector?`, `set?`, `list?`, `seq?`, `fn?` |
| Higher-order | `comp`, `partial`, `complement`, `identity`, `constantly`, `juxt`, `fnil` |
| Threading | `->`, `->>`, `as->`, `cond->`, `cond->>`, `some->`, `some->>` (macros) |
| Meta | `meta`, `with-meta`, `vary-meta` |
| Vars | `var`, `deref`, `alter-var-root!`, `ns-resolve` |
| Printing | `print`, `println`, `pr`, `prn`, `str`, `pr-str`, `tap>` |

### 17.2 Namespaces

| Namespace | Purpose |
|---|---|
| `nexis.core` | Everything in §17.1 |
| `nexis.db` | `open`, `ref`, `with-tx`, `with-read-tx`, `put!`, `alter!`, `delete!`, `cursor`, `scan`, etc. |
| `nexis.string` | Extended string ops |
| `nexis.math` | Floating-point helpers, bit-ops |
| `nexis.simd` | Typed-vector kernels |
| `nexis.test` | Test runner, `deftest`, `is`, `are` |
| `nexis.pprint` | Pretty-printer |
| `nexis.repl` | REPL-specific helpers |

### 17.3 What's explicitly missing from v1 stdlib

- No `clojure.spec` equivalent.
- No `core.logic`-style logic programming.
- No `clojure.java.io` (no JVM).
- No `format` (Clojure's CL-style format string) — v1 uses `str` + explicit interpolation.

---

## 18. Tooling

### 18.1 CLI `nexis`

- `nexis` → REPL.
- `nexis file.nx` → run a file.
- `nexis -x '(println :hi)'` → one-shot expression.
- `nexis -t < file.nx` → print tokens.
- `nexis -s < file.nx` → print Forms (post-read, pre-expansion).
- `nexis -m < file.nx` → print macroexpanded Forms.
- `nexis -b < file.nx` → print bytecode.
- `nexis --compile file.nx -o file.nx.o` → produce an object file.
- `nexis --run file.nx.o` → load and run an object file.
- `nexis --disasm file.nx.o` → disassemble.

### 18.2 REPL features

- Line editing, history, persistent history file.
- `/help`, `/doc sym`, `/source sym`, `/ns`, `/reload`, `/macroexpand 'form`, `/disasm 'fn`, `/time 'expr`, `/profile 'expr`, `/tap-listen`, `/quit`.
- `*1`, `*2`, `*3`, `*e` for history and last exception.
- Tab completion on symbols in scope.

### 18.3 Test runner

- `(deftest my-test (is (= 1 (inc 0))))` — defines a test var.
- `nexis --test src/` → loads all files, runs all `deftest`s, prints results.
- `nexis --test-ns my.ns` → runs tests in one namespace.
- Property-based tests via `(defspec my-prop n gen prop)` (later milestone; use a simple generator library).

### 18.4 Debugging

- `(dbg x)` — prints value with source location and returns it. Usable in threading macros.
- `(tap> x)` — sends to any REPL-attached inspector.
- Stack traces include source spans and, where available, macro-expansion provenance.

### 18.5 Disassembler

Adapted directly from em's `-b` output. Example:

```
fn user/inc-ages
  slots=3 upvalues=0 arity=1
  0000  coll:vec-nth        s:1  s:0  c:0     ; s:1 = (s:0 nth 0)
  0008  math:inc            s:2  s:1  -       ; s:2 = inc(s:1)
  0010  call:return         s:2  -    -
```

Letters: `s` slot, `c` constant, `v` var, `u` upvalue (hot-path four) · `i` intern, `j` jump, `e` durable (context-local three).

---

## 19. SIMD & Performance

### 19.1 Where SIMD goes

Not in the default collection types. SIMD lives on explicitly typed homogeneous vectors:

- `byte-vector`, `int32-vector`, `int64-vector`, `float32-vector`, `float64-vector`.
- Kernels in `nexis.simd`: `vadd`, `vmul`, `vdot`, `vreduce-sum`, `vmap`, `vfilter-into`, `vcount-if`.
- Implementation uses Zig's `@Vector(N, T)` primitives; N chosen per target ISA.

### 19.2 Compiler specialization

Low-risk wins that v1 takes:

- **Small fixnum fast path** — arithmetic on two fixnums compiles to a direct `math:add` with no boxing.
- **Static collection literals** — fully static `[1 2 3]` or `{:a 1}` is built once at load time and placed in the literal pool.
- **Branch prediction hints** on `nil?`, `zero?` — common predicates emit a hinted `jump:f` / `jump:t`.

*(Keyword-as-function — `(:foo m)` as sugar for `(get m :foo)` — is not a v1 language feature. If added later, it's a macro or a compiler specialization and requires a §6 / §17 amendment first. See §24.)*

### 19.3 What we deliberately defer

- Inline caches on Var loads (the revision counter is there; the mechanism isn't).
- Method-call inline caching.
- Any form of JIT.
- Generational GC.
- Collection-type specialization beyond the HAMT/RRB/array-map distinction.

### 19.4 JIT readiness (v2 path)

**nexis v1 is interpreter-only.** But the architecture is designed so that a future JIT is a matter of adding a tier, not reworking foundations. Concrete JIT-friendly properties:

| Property | Why it helps a JIT |
|---|---|
| Fixed-width 64-bit bytecode | Trivial linear scan for compilation units; no variable-length decode |
| Slot/register VM | Slots map directly to host registers or stack slots — no "simulate a stack" overhead |
| Tail-call dispatched interpreter | Each handler already looks like a JIT basic-block ending in a jump |
| Per-routine tables | Compilation unit is self-contained; no global resolution needed |
| Non-moving GC | No pointer-update barriers in generated code; safer pointer-tagging math |
| Uniform tagged Value | Single shape for type-check prefix + fast-path + slow-path fallback |
| Revision counter on Vars | Built-in invalidation token for inline caching |
| Single-threaded v1 | No thread safety in generated code yet |
| Safepoint discipline (backward branches, call sites) | Preserved from v1 even without a JIT, so Phase 2+ doesn't retrofit |

Three plausible JIT paths, ranked by effort:

1. **Copy-and-patch JIT** (Xu et al., PLDI 2021) — each opcode handler is written once as a template, `clang` compiles it to a relocatable snippet at VM build time, and the runtime stitches snippets together for hot functions with operand patching. Proven: CPython 3.13 uses exactly this approach and measured ~10–15% speedups on warm code with ~500 LOC of JIT glue. **Effort: 2–4 months post-v1. Expected speedup: 2–4× on warm code.** This is the right first JIT for nexis.
2. **Template/baseline JIT** (V8 Sparkplug style) — translate bytecode to native with no optimization, one bytecode op ≈ a few machine instructions. **Effort: 6–12 months. Expected speedup: 3–5×.**
3. **Optimizing JIT via Cranelift or LLVM** — lower to IR, let the backend do heavy lifting. **Effort: years. Expected speedup: approaches LuaJIT/V8 tier for specialized code.**

**Apple Silicon JIT specifics:** macOS requires `MAP_JIT` pages with `pthread_jit_write_protect_np` to toggle W^X. Distribution requires the `com.apple.security.cs.allow-jit` entitlement. Zig 0.16 handles both cleanly. iOS JIT is not permitted and is not a target.

### 19.5 Apple Silicon UMA — Metal dispatch for large typed vectors

M-series chips give the CPU, GPU, and Neural Engine a **unified memory pool**. A buffer allocated for CPU use is accessible to the GPU with zero-copy. For nexis this is not relevant to the VM itself (GPUs are hostile to pointer-chasing interpreter code), but it matters at one specific boundary:

- **`nexis.simd` kernels on large typed vectors** can dispatch to Metal Performance Shaders (MPS) without copying data.
- Crossover point measured per-op: below ~10k elements, NEON beats GPU dispatch overhead; above that, MPS wins materially.
- Implementation: a thin Zig ↔ Objective-C binding layer, activated when a typed-vector kernel is called with a sufficiently large input.
- Language surface: unchanged. `(simd/vdot xs ys)` is the same call; the dispatch is internal and opportunistic.

This is a **v2 feature**. The PLAN ensures `nexis.simd` is the delegation boundary so it can be added non-disruptively. Bandwidth on M-series LPDDR5 (200–400 GB/s) makes this genuinely interesting for analytical / numerical workloads on large vectors — a place where most managed-runtime languages can't easily compete.

A v3+ possibility worth naming: **GPU kernels over emdb pages.** Because emdb pages are mmap'd into the same physical pool the GPU can access on UMA, in principle a Metal kernel could scan a named tree directly with no copy. DuckDB and a few column stores have begun experimenting with similar UMA-aware query offload. Not a v1 goal; just not architecturally blocked.

### 19.6 Zig-specific performance wins — the reason nexis will be the fastest Lisp ever shipped

Clojure's performance ceiling is set by the JVM: every value is a reference to a heap object with a 12–16 byte header, collection elements are boxed, class-loading is slow, the GC pauses are what they are, and source code lives in UTF-16 Strings. nexis on Zig is not bound by any of those.

Wins organized by tier: **v1 (free from architecture)**, **Phase 6 (dedicated engineering)**, **v2+ (research / ambitious)**.

#### Tier 1 — v1-gettable (baked into our architecture)

These are wins we inherit directly from the design choices already in this PLAN. No extra engineering beyond competent implementation.

| # | Win | Mechanism | Expected impact |
|---|---|---|---|
| T1.1 | **Tagged 16-byte Value** vs JVM Object reference | Immediates (nil, bool, char, fixnum, kw, sym, float) live entirely in the Value. Zero heap, zero indirection, zero GC for the common case. | **2–4× on arithmetic-heavy code** before any JIT. |
| T1.2 | **Value fits a single 128-bit SIMD register** | On NEON (M-series) or SSE (x86), a Value is `@Vector(2, u64)`. Equality, tag extraction, move — all single-cycle vector ops. | Pervasive micro-wins across every runtime op. |
| T1.3 | **Arena allocation for compile-time intermediates** | Macro-expansion Forms, IR nodes, and analyzer structures live in a scoped bump allocator. Freed en masse when compilation ends. | **Zero GC pressure during compilation.** Macro-heavy bootstrap becomes dramatically faster. |
| T1.4 | **8-byte zero-copy tokens from mmap'd source** | nexus-generated lexer produces `{pos: u32, len: u16, cat: u8, pre: u8}` tokens pointing into the mmap. No UTF-16 re-encoding, no substring allocation. SIMD comment-skip. | Parse is I/O-bound, not CPU-bound. |
| T1.5 | **Cache-friendly frame layout** | Contiguous array of 16-byte Values on a bump-allocated stack. L1 (32–64 KB) fits 2000–4000 slots. | Function calls and `let` bindings stay in L1. |
| T1.6 | **Packed bytecode + literals, mmap'd** | `.nx.o` files mapped directly — no class-load, no parse, no verification. Routine callable the instant the file is mapped. | **Sub-millisecond cold start** realistic. **10–50× faster than JVM class-loading.** |
| T1.7 | **SIMD string equality and hashing** | `std.mem.eql` auto-vectorizes; xxHash3 is natively SIMD. | **~2× faster** than Java's char-by-char String comparison on strings >16 bytes. |
| T1.8 | **Direct-indexed interned keyword table** | `u32` intern ids → direct array index, one memory access. Java does `ConcurrentHashMap` lookup + weak-ref deref. | **~5× faster keyword equality** on already-interned keywords. |

#### Tier 2 — Phase 6 performance pass (known techniques, real engineering)

Wins that require dedicated work in Phase 6 but rest on well-documented algorithms.

| # | Win | Mechanism | Expected impact |
|---|---|---|---|
| T2.1 | **SIMD-packed CHAMP nodes** | Packed `{data_bitmap: u32, node_bitmap: u32, entries..., children...}`. Use NEON `CNT` for popcount (index computation), `@Vector(8, u64)` for parallel key compare on small nodes, prefix-sum for insertion position. | **2–3× faster map lookup** on medium HAMTs. Clojure can't reach this because JVM Object arrays prevent packing. |
| T2.2 | **Zero-copy string/bytes from emdb** | Immutable strings/byte-vectors read from emdb carry a Value whose payload points directly into the mmap page. No allocation, no copy. Lifetime tied to read-tx. | **10–50× speedup** on database reads of large string/blob values. |
| T2.3 | **Inline caches on Var loads** | Per-Var revision counter (§13.3) drives compile-time inline cache cells in bytecode. First call fills; subsequent calls bypass Var indirection. | **2–5× on call-heavy code** once caches warm. V8/HotSpot-tier technique. |
| T2.4 | **Perfect hash for load-time keywords** | Compile-time generation (gperf/CHD-style) of keyword-text → intern-id mapping for each routine. | Sub-nanosecond keyword materialization. |
| T2.5 | **LuaJIT-style operand-specialized opcodes** | Phase 6 emits `math:add-ss`, `math:add-sc`, etc. instead of the generic op. Zero kind dispatch on the hot path. | **10–30% on numeric loops.** |
| T2.6 | **Generational GC nursery** (if STW pauses become visible) | Add a bump-allocator nursery with a write barrier; promote survivors to the non-moving old generation. | Sub-millisecond young-gen pauses even on large heaps. |
| T2.7 | **SIMD kernels on typed homogeneous vectors** | `float64-vector`, `int32-vector`, etc. use Zig's `@Vector(N, T)` compiling to optimal native SIMD. | `vdot` / `vsum` / `vfilter` approach **~40 GFLOPS peak** on modern cores. |
| T2.8 | **Branchless CHAMP lookup for small bitmaps** | When a node has ≤8 entries, linear SIMD-compare beats bitmap math. | Sub-3-ns lookup for small maps. |
| T2.9 | **Precomputed source maps in .nx.o** | Lazy materialization of stack traces: compact encoding of PC→span, decoded only when an exception is actually raised. | Zero normal-path cost for source-mapping. |

#### Tier 3 — v2+ research / ambitious

Wins that are architecturally available but require substantial investment, or rest on unproven territory.

| # | Win | Mechanism | Expected impact |
|---|---|---|---|
| T3.1 | **Copy-and-patch JIT** (Xu et al. PLDI 2021) | Each opcode handler as a Zig template; clang compiles to relocatable snippets at VM build time; runtime stitches them per-function with operand patching. CPython 3.13 uses this. Zig's `comptime` makes it especially clean. | **2–4× on warm code.** Closes most of the gap to LuaJIT's interpreter mode. |
| T3.2 | **Apple Silicon Metal dispatch for large typed vectors** | Crossover point (~10k elements) dispatches `nexis.simd` kernels to MPS with zero-copy (UMA). | **20–100×** on large-vector numerics. **No managed-runtime language can easily match this.** |
| T3.3 | **Shared read-only mmap of .nx.o across processes** | Multiple nexis worker processes running the same code share one physical copy of the bytecode. | Massive memory savings in fleet/server deployments. JVM can't do this cleanly. |
| T3.4 | **Lock-free concurrent intern table via RCU** | Epoch-based RCU for multi-isolate v2+. Zero-cost reads, writes bump a generation. | Scales to dozens of isolates without intern-table contention. |
| T3.5 | **Zero-copy CHAMP over emdb pages** (research) | For very large read-mostly maps, use emdb B+ tree pages as CHAMP backing. Values point directly into mmap. | **Potentially spectacular** on analytical / lookup-heavy workloads. Not committed; kept architecturally open. |
| T3.6 | **Full AOT compilation to native** | Beyond copy-and-patch: generate real native code per routine via Cranelift or Zig's own backend. | **Approaches LuaJIT / V8** on specialized code. Multi-year project. |

### 19.7 Realistic performance targets

Based on a reasonable implementation of **Tier 1 + Tier 2** (not yet Tier 3), nexis's expected performance profile at v1 launch:

#### vs Clojure on the JVM

| Workload | vs Clojure 1.12 |
|---|---|
| Cold startup (launch + first result) | **10–50× faster** (mmap'd routines, no class-loading, no JIT warmup) |
| Simple arithmetic loop (`(reduce + (range 1000000))`) | **2–4× faster** (no boxing, no indirection) |
| Map lookup on 100k-entry persistent map | **2–3× faster** (SIMD CHAMP + interned keyword `==`) |
| String-heavy processing | **~2× faster** (UTF-8 native, SIMD eq/hash) |
| Database read of 10k records (via Datomic/Datahike vs emdb) | **10–50× faster** (zero-copy from mmap vs JDBC deserialization) |
| Persistent vector `conj` 1M times | **~1.5× faster** (better allocator, no boxing) |
| Large typed-vector dot product (1M float64) | **20–100× faster** (SIMD kernel, direct f64 layout) |

#### vs LuaJIT (the gold standard for interpreter-tier dynamic languages)

| Workload | vs LuaJIT |
|---|---|
| Tight arithmetic loop | ~2–3× slower (they JIT; we don't in v1) |
| Collection-heavy code | **Competitive or better** (they don't have persistent HAMT/CHAMP; we do) |
| Database-integrated | **Much faster** (no comparable zero-copy story in LuaJIT) |
| Startup | **~5× faster** (no require() chain, mmap'd `.nx.o`) |

Once we add the Tier 3 **copy-and-patch JIT** in v2, the arithmetic-loop gap to LuaJIT closes to within ~20–50%, while we keep every collection and database advantage.

#### Headline positioning (aspirational)

> **nexis aims to be the fastest interpreter-tier Lisp ever shipped.** Against Clojure specifically, we expect it to feel dramatically crisper on cold start, competitive-to-faster on collection work, and substantially faster on database-integrated workloads. When JIT support lands in v2, the remaining gap to LuaJIT / V8 / HotSpot-tier performance is expected to narrow substantially.

This is an aspiration, not a shipping guarantee. Every Tier 1 and Tier 2 win above maps to a specific, committed PLAN.md section. **Headline performance claims will be published alongside v1 with honest measured numbers** — not asserted in advance.

### 19.8 Performance gates

Benchmarks live in `test/bench/`:

- `bench-collections.nx` — assoc, dissoc, conj, nth over sizes 1, 8, 32, 128, 1k, 32k, 1M.
- `bench-vm.nx` — simple arithmetic loops, closure creation, tail calls.
- `bench-db.nx` — put/get/scan throughput against emdb, including zero-copy string/bytes paths.
- `bench-simd.nx` — typed-vector kernel throughput (vdot, vsum, vmap).
- `bench-startup.nx` — end-to-end cold-start latency from CLI invocation to first expression evaluated.
- `bench-vs-clojure.nx` — side-by-side workloads benchmarked against Clojure 1.12 where feasible.

**Target at v1 ship**:
- Match the Tier 1 + Tier 2 projections in §19.7 within ±30%.
- Be the fastest non-JIT Lisp in every public benchmark suite we can find.
- Publish a formal benchmark report alongside v1.

These gates are **informational in v1, not blocking**. Phase gates (§20) focus on correctness. But we commit to publishing honest performance numbers at ship time.

**Methodology contract (frozen).** Every comparative performance
claim nexis publishes — especially in comparison to Clojure —
follows the discipline pinned in `docs/BENCH.md`. That document
covers the four fairness standards (numerical / accurate / fair /
relevant), the benchmark category taxonomy (startup / warm micro /
steady-state / collection / memory / database / macro), the
statistical reporting rules (median + p5/p95/p99; no arithmetic
mean over GC pauses; no speedup multiples without absolute
numbers), the Clojure-community conventions we adopt (`criterium`,
`*warn-on-reflection*`, tiered arithmetic idioms, transients where
the community uses them, stock JDK flags), the reproducibility
contract (source + raw data + versions + hermeticity script), and
the honesty clause (scenarios where Clojure wins are published,
not omitted). Pre-publication review by at least one Clojure
practitioner outside the nexis team is required before any
comparative benchmark report ships. See `docs/BENCH.md` §11 for the
summary sentence every such report must survive. Landing that
document before any benchmark code is intentional — the commitments
it makes are strongest when they cannot be retrofitted against
favorable measurements.

---

## 20. Testing Strategy & Phase Gates

### 20.1 Layered tests

| Layer | Focus | Example |
|---|---|---|
| Unit | Zig-level tests on runtime primitives | `Value` encoding, HAMT assoc/dissoc, hash invariants |
| Property | Randomized laws | Equality laws, persistent immutability, codec round-trip |
| Integration | End-to-end | REPL session, compile-and-run, transaction flow |
| Golden | Compiler output stability | `.nx → bytecode` byte-for-byte against checked-in expected output |
| Fuzz | Parser + codec robustness | Malformed source, malformed blobs |
| Bench | Performance regression | Throughput/latency tables over time |

### 20.2 Phase exit gates

#### Phase 0 gate
- `nexis.grammar` compiles via `nexus` to `src/parser.zig`.
- Parser round-trips representative source files to `Sexp`.
- Golden test covers every reader construct in §7.2.

#### Phase 1 gate (THE BIG ONE — this is the runtime testbed)
Before any compiler work proceeds, the following must pass:

1. **100k+ randomized equality/hash tests**: reflexivity, symmetry, transitivity, hash consistency, metadata non-effect on equality/hash, across all value kinds.
2. **Persistent immutability property**: arbitrary sequences of `assoc/dissoc/conj/pop` on maps/sets/vectors never mutate the source value.
3. **Transient equivalence**: for any edit sequence, persistent path and transient-then-persistent path yield `=` results.
4. **Transient ownership**: using a transient after `persistent!` throws; using from "wrong" owner throws.
5. **Codec round-trip**: `(= v (decode (encode v)))` for 10k randomized values; hash preserved.
6. **emdb round-trip**: writing 10k values across N named trees, then reading them back, yields structural equality for all; named trees are independent.
7. **GC stress**: allocate-heavy workloads interleaved with forced collections; no leaked/corrupted objects; all live data survives; no dangling headers.
8. **Interning invariants**: same textual symbol → same intern id across reads; namespace qualification preserved.

**Only after these pass does Phase 2 start.** This is the single most important gate in the project.

#### Phase 2 gate
- Compiler round-trips: every Phase 1 value constructible as a Form → compiled → executed produces an `=` runtime value.
- VM executes core forms: `if`, `let`, `fn`, `loop`/`recur`, `do`, `quote`, `throw`/`try`.
- Tail-call stress test: deeply recursive `recur` runs in constant space.
- Closure capture/mutation correctness.

#### Phase 3 gate
- Macro expansion fixpoint on representative test suite.
- Namespace load/reload preserves Var identities.
- Syntax-quote + auto-gensym works for canonical macros (`when`, `-> `, `cond`, `defn`).

#### Phase 4 gate
- `with-tx` / `with-read-tx` correctly abort on exception.
- Concurrent read + writer on a single DB: readers see snapshot consistency, writers succeed (even though v1 only actually runs one at a time, the read-tx holds a snapshot).
- Durable-ref equality/hash based on identity only.
- `db/cursor` scans match insertion order for sorted keys.

#### Phase 5 gate
- REPL survives 10k-line session without leaking.
- Stack traces correctly source-map to original files and lines.
- Test runner discovers, runs, and reports.

### 20.3 CI structure

- `zig build test` — all unit + property tests (target: <10s).
- `zig build integration` — end-to-end suite (target: <60s).
- `zig build fuzz` — fuzz parser and codec (longer, on-demand).
- `zig build bench` — benchmarks.
- `zig build golden` — golden compiler output + regenerate flag.

---

## 21. Roadmap & Milestones

Each phase has a crisp entry criterion (previous gate passed) and exit criterion (next gate).

### Phase 0 — Foundations (weeks 1–2)

**Goal**: commit to semantics before code. Land the minimum artifacts a fresh implementation session needs to begin Phase 1 without ambiguity.

**Deliverables**:

- [ ] `nexis.grammar` — the full reader grammar covering §7.2, designed to produce canonical Form shapes (see Appendix C).
- [ ] `src/nexis.zig` — the `@lang` module: Tag enum, any lexer wrapper (expected minimal/none), plus re-exports nexus needs.
- [ ] `build.zig` with `zig build parser` (runs `../nexus/bin/nexus nexis.grammar src/parser.zig`), `zig build test`, `zig build golden`.
- [ ] `build.zig.zon` pinning Zig 0.16.0 and emdb version.
- [ ] `docs/SEMANTICS.md` — pinned short spec covering:
  - equality rules for every value kind (cross-type collection equality from §6.6, numeric corner cases including NaN / -0.0 / ±Inf / overflow promotion, metadata non-interference)
  - hash consistency invariants
  - nil propagation rules (§6.5)
  - cross-type equality examples with expected results
  - truthiness (§6.2)
  - print/read round-trip contract for each serializable kind
- [ ] `docs/FORMS.md` — canonical Form schema (Appendix C lifted into its own doc for easy reference), reader-to-Form normalization rules, reader/normalizer/macroexpander responsibility boundaries.
- [ ] `docs/CODEC.md` (stub) — serializability matrix (from §15.10), wire-format specification, round-trip invariants.
- [ ] `test/golden/basic.{nx,sexp}` — canonical reader round-trip over a representative source file.
- [ ] `test/golden/reader-literals.{nx,sexp}` — explicit coverage of every reader construct: numbers (int/hex/binary/real, negative), strings with all escapes, chars (named + `\u{HEX}`), keywords (with and without namespace), symbols (same), maps/vectors/sets/lists, quote/syntax-quote/unquote/splice, `@deref`, metadata sugar (`^:kw`, `^{...}`, `^sym`), `#_` discard, `#(...)` anon-fn.
- [ ] `test/golden/errors/` — negative reader tests:
  - odd map arity
  - duplicate statically-detectable literal keys in maps/sets
  - nested `#(...)` (must reject)
  - `~@` outside a syntax-quote context
- [ ] `README.md` updated with mission statement, status, and pointers to PLAN.md / CLOJURE-REVIEW.md.
- [ ] `AGENTS.md` — AI/contributor routing guide: "read PLAN.md, FORMS.md, SEMANTICS.md; ZIG-0.16.0-REFERENCE.md is mandatory before writing Zig."
- [ ] Directory layout established (§22).

**Exit**:
- Source parses via `zig build parser && zig build test`.
- Forms come out matching Appendix C / FORMS.md canonical shapes.
- `docs/SEMANTICS.md` is reviewed and signed off — every semantic corner case has an explicit decision.
- All golden tests pass byte-for-byte.

### Phase 1 — Runtime core, no compiler (weeks 3–8) — **critical**

**Goal**: have the entire data universe working before a single bytecode instruction executes.

- [ ] `src/value.zig`: 16-byte Value type, tag accessors, immediates, heap pointer handling.
- [ ] `src/heap.zig`: allocator + HeapHeader + type-tagged dispatch.
- [ ] `src/intern.zig`: symbol and keyword intern tables.
- [ ] `src/string.zig`: string heap kind.
- [ ] `src/bignum.zig`: minimum viable arbitrary-precision integer (could wrap a library; prefer pure Zig).
- [ ] `src/coll/hamt.zig`: persistent map and set.
- [ ] `src/coll/rrb.zig`: persistent vector.
- [ ] `src/coll/list.zig`: immutable cons list.
- [ ] `src/coll/transient.zig`: transient wrappers with owner token.
- [ ] `src/hash.zig`: xxHash3-based hashing with structural combine for collections.
- [ ] `src/eq.zig`: `identical?` and `=` implementations.
- [ ] `src/gc.zig`: mark-sweep, precise root enumeration interface (roots registered by caller).
- [ ] `src/codec.zig`: serialize/deserialize Value ↔ bytes.
- [ ] `src/db.zig`: emdb connection, durable-ref value, `put/get/delete/cursor/scan` raw ops.
- [ ] `test/prop/*.zig`: property-based tests listed in §20.2 Phase 1 gate.

**Exit**: all Phase 1 gate tests pass.

### Phase 2 — Compiler and VM (weeks 9–14)

- [ ] `src/reader.zig`: Sexp → Form.
- [ ] `src/resolve.zig`: Form → Resolved (symbols → slot/upvalue/var/special).
- [ ] `src/analyze.zig`: closure analysis, tail-position detection, literal lifting.
- [ ] `src/bytecode.zig`: 64-bit instruction encoding (adapted from em).
- [ ] `src/compile.zig`: IR → bytecode.
- [ ] `src/vm.zig`: frame/slot machine, tail-call dispatcher, handlers for groups 0–7.
- [ ] `src/loader.zig`: bytecode module loading and linking.
- [ ] `src/fn.zig`: function/closure runtime representation.

**Exit**: Phase 2 gate; can run `let`, `if`, `fn`, `loop`/`recur`, `do`, `quote`, exception handling.

### Phase 3 — Macros, namespaces, REPL (weeks 15–18)

- [ ] `src/namespace.zig`: Namespace, Var cell, unbound marker, revision counter.
- [ ] `src/macroexpand.zig`: fixpoint expander.
- [ ] `src/syntax_quote.zig`: syntax-quote, auto-gensym.
- [ ] `src/repl.zig`: interactive shell (adapted from em).
- [ ] `src/dynamic.zig`: dynamic binding stack.
- [ ] `src/stdlib/core.nx`: core macros (`when`, `->`, `->>`, `cond`, `let`, `if-let`, `defn`, etc.) written in nexis itself.

**Exit**: Phase 3 gate; REPL usable for real programs; core stdlib loaded.

### Phase 4 — emdb integration as a first-class concept (weeks 19–22)

- [ ] `src/tx.zig`: `with-tx` / `with-read-tx` compile and runtime contract.
- [ ] Durable-ref special handling in `coll` + new `tx` opcodes.
- [ ] `src/stdlib/db.nx`: library wrapper for user-facing API.
- [ ] Codec v1 frozen; version-tagged for forward compatibility.
- [ ] Cursor and scan exposed.

**Exit**: Phase 4 gate; a small application (e.g. a to-do tracker with persistent state) works end-to-end.

### Phase 5 — Standard library and tooling (weeks 23–26)

- [ ] Remainder of `nexis.core` written in nexis itself on top of primitives.
- [ ] `nexis.test`, `nexis.pprint`, `nexis.string`, `nexis.math`, `nexis.repl`.
- [ ] `nexis --compile` / `--run` / `--disasm` subcommands.
- [ ] Test runner.
- [ ] Source-mapped stack traces end-to-end.

**Exit**: Phase 5 gate; realistic user experience.

### Phase 6 — Performance pass (weeks 27–30)

Phase 6 delivers the **Tier 2 performance wins** from §19.6. Each item maps to a specific projected speedup:

- [ ] **Inline caches on Var loads** (T2.3) — use the per-Var revision counter. Target: 2–5× on call-heavy code.
- [ ] **SIMD-packed CHAMP nodes** (T2.1) — NEON `CNT`, parallel key-compare via `@Vector(8, u64)`, prefix-sum for insertion position. Target: 2–3× faster map lookup.
- [ ] **Zero-copy string/bytes from emdb** (T2.2) — Value payload can point directly into mmap pages for immutable strings/byte-vectors. Target: 10–50× on DB reads of large values.
- [ ] **Perfect-hash keyword tables** (T2.4) — compile-time generation of keyword text → intern id.
- [ ] **LuaJIT-style operand-specialized opcodes** (T2.5) — `math:add-ss`, `math:add-sc`, etc.
- [ ] **Generational GC nursery** (T2.6) — only if mark-sweep pauses become visible in benchmarks.
- [ ] **`nexis.simd` kernels on typed vectors with benchmarks** (T2.7) — `vdot`, `vsum`, `vmap`, `vfilter`.
- [ ] **Branchless CHAMP lookup for small bitmaps** (T2.8).
- [ ] **Precomputed compact source maps** (T2.9) — lazy stack-trace materialization.
- [ ] **`bench-vs-clojure.nx`** and other benchmark suites for CI regression detection.
- [ ] **Publish performance report** with v1 shipping numbers vs Clojure and LuaJIT.

**Exit**: performance numbers published; clear comparison table vs Clojure and vs bare emdb.

### Phase 7 — 1.0 polish

- [ ] Documentation site.
- [ ] Example applications.
- [ ] Error message review pass — every user-visible error hand-checked for clarity.
- [ ] Stability audit and spec freeze.

**Beyond 1.0 (non-binding)**:

- Multi-isolate runtime via Nexus orchestrator.
- User-extensible protocols.
- `as-of` historical reads.
- Storage-native collection variants.
- Zig-level FFI story.
- Native compilation (AOT via LLVM or Zig's backend).

---

## 22. Repository Layout

```
nexis/
├── README.md
├── PLAN.md                           (this document)
├── LICENSE
├── build.zig
├── build.zig.zon
├── nexis.grammar                     source of truth for reader
├── src/
│   ├── main.zig                      CLI entry point
│   ├── parser.zig                    generated by nexus — do not edit
│   ├── nexis.zig                     Tag enum + lexer wrapper for nexus
│   ├── reader.zig                    Sexp → Form
│   ├── value.zig                     16-byte Value + heap header
│   ├── heap.zig                      allocator
│   ├── gc.zig                        mark-sweep collector
│   ├── intern.zig                    symbol/keyword intern
│   ├── string.zig
│   ├── bignum.zig
│   ├── coll/
│   │   ├── hamt.zig                  persistent map + set
│   │   ├── rrb.zig                   persistent vector
│   │   ├── list.zig
│   │   ├── transient.zig
│   │   └── typed_vector.zig
│   ├── hash.zig
│   ├── eq.zig
│   ├── codec.zig                     serialize/deserialize
│   ├── db.zig                        emdb connection + durable ref
│   ├── tx.zig                        transaction runtime
│   ├── namespace.zig                 Namespace + Var
│   ├── macroexpand.zig
│   ├── syntax_quote.zig
│   ├── resolve.zig
│   ├── analyze.zig
│   ├── bytecode.zig                  ISA encoding (borrowed from em)
│   ├── compile.zig                   IR → bytecode
│   ├── vm.zig                        runtime engine
│   ├── fn.zig                        function/closure
│   ├── dynamic.zig                   dynamic binding stack
│   ├── loader.zig                    object-file loading
│   ├── repl.zig
│   └── simd.zig                      typed-vector kernels
├── stdlib/
│   ├── core.nx                       macros and higher-order fns in nexis
│   ├── db.nx
│   ├── string.nx
│   ├── math.nx
│   ├── test.nx
│   ├── pprint.nx
│   └── repl.nx
├── docs/
│   ├── SEMANTICS.md                  pinned equality/hash/nil spec
│   ├── ISA.md                        bytecode instruction set
│   ├── PIPELINE.md                   source → bytecode flow
│   ├── REPL.md
│   ├── DB.md                         durable-ref + transaction spec
│   ├── MACROS.md
│   └── ZIG-0.16.0-REFERENCE.md       (already present)
├── test/
│   ├── unit/                         Zig-level tests
│   ├── prop/                         property-based tests
│   ├── integration/
│   ├── golden/
│   ├── fuzz/
│   └── bench/
├── examples/
│   ├── todo.nx
│   ├── wordcount.nx
│   └── graph.nx
├── bin/                              build output
└── AGENTS.md                         AI/contributor routing guide
```

---

## 23. Hard Decisions (Frozen)

The following are architectural decisions committed to now, before code is written, to prevent drift. Each requires a PLAN.md amendment with stated rationale to change.

1. **16-byte tagged Value**, not NaN-boxed, not 24-byte.
2. **Tracing mark-sweep GC**, not reference counting, not hybrid.
3. **Slot/register VM**, not stack VM. Reuse em's 64-bit ISA shape.
4. **Heap-first persistent collections**. No mmap-native HAMT in v1.
5. **Single-isolate, single-threaded v1**. No threads, no parallelism.
6. **Explicit lexical transactions**. No ambient tx magic. No STM.
7. **Durable refs as identity**, not cached value. Equality/hash identity-based.
8. **No user protocols in v1**. Built-in polymorphism only.
9. **No multimethods, agents, core.async, reader conditionals in v1**.
10. **Integers are fixnum + bignum. Floats are f64. No rationals, no decimals.**
11. **`(= 1 1.0)` is `false`.** Cross-type numeric equality is opt-in via `==`.
12. **Metadata never affects equality or hash.**
13. **Only `nil` and `false` are falsy.**
14. **Eager by default.** Laziness only at cursor boundaries.
15. **Reader is minimal.** Sugar is via macros.
16. **Syntax-quote has auto-gensym, not full hygiene.**
17. **Three representations (Form, Value, Encoded) are kept distinct.**
18. **Mark-sweep first, generational only if needed.**
19. **`recur` is semantically guaranteed constant-space; general TCO is a best-effort compiler optimization.**
20. **Vars are the REPL redefinition mechanism.** Global function references are invoked via Var indirection by default (new calls see the latest root). Lexical locals and captured upvalues compile directly without indirection (no redefinition effect on captures).
21. **Operand kinds**: 4 hot-path `SCVU` (S=0 slot, C=1 constant, V=2 var, U=3 upvalue) + 3 context-local (`i` intern, `j` jump, `e` durable). Encoding order *is* the mnemonic, ordered by hot-path frequency. LuaJIT-style operand-specialized opcode variants reserved for Phase 6.
22. **`as-of` reads are v1**, not deferred. emdb's MVCC already provides the machinery; exposing it is library code.
23. **LMDB is emdb's ancestor. Datomic is the semantic reference for durable-as-value.** When a design choice is ambiguous, first ask what LMDB / Datomic / Clojure / LuaJIT do.
24. **Form is a recursive wrapper type with inline fields.** `{datum, origin, user_meta, ann}`. No global side-tables. Macros see/produce Forms.
25. **Serialization has a fixed v1 scope** (§15.10). nil, bool, char, fixnum, bignum, f64, string, kw/sym (as text), list, vector, map, set, byte-vector, typed-vector, durable-ref. Functions, vars, transients, namespaces, tx handles, and error traces are **not serializable** in v1; the codec throws `:unserializable`.
26. **Character and string escapes are unified on `\u{HEX}`.** Clojure-style named chars for the common set. Single-char `\a` syntax retained.
27. **Block comments dropped.** Only `;` (line), `#_` (discard next form), `(comment ...)` (macro).
28. **`#(...)` anonymous fn** is lowered post-read to an internal form (e.g. `#%anon-fn`), not resolved by the reader. Nested `#(...)` is an error.
29. **Backtick reads as `syntax-quote`**, not `quasiquote`. Full Clojure-style qualification + auto-gensym semantics implemented at the macro-expansion layer.
30. **Persistent vector is plain 32-way trie with tail buffer in v1** (§9.2). RRB relaxation is v2+. This matches exactly what Clojure has shipped for 17+ years.
31. **Compiler knows only `*`-suffixed primitives** (§6.1): `let*`, `fn*`, `loop*`, `letfn*` plus the un-starred `def`, `if`, `do`, `quote`, `var`, `set!`, `recur`, `try`, `throw`. All user-facing `let`, `fn`, `loop`, `letfn`, `defn` are macros in `stdlib/core.nx`. Two-stage bootstrap.
32. **Keyword / symbol asymmetry** (§8.4): keywords interned, metadata-less, callable; symbols interned in common case, heap-wrapped when metadata-bearing. Hash domains are separated to avoid HAMT collision.
33. **Keyword-as-function is a v1 language feature** (§8.7): `(:k m)` = `(get m :k)`, `(:k m default)` = `(get m :k default)`. Not a late specialization.
34. **Macros receive `(&form, &env, user-args...)`** (§14.1), not just `Form → Form`. `&env` is a deliberately shallow `symbol → LocalBinding` map in v1.
35. **`seq` is a core v1 abstraction** (§6.6), not a deferred niceness — confirmed by reading Clojure source. Direct fast paths on maps/vectors/typed-vectors bypass seq when that's clearer.
36. **Cross-type sequential equality** (§6.7): list, vector, lazy-seq, and cons are mutually equal if element-wise equal. Map and set are their own equality categories. Hashes are constructed so the invariant holds by design.
37. **CHAMP is the committed persistent-map target** (§9.1), not a stretch goal. Separate data/node bitmaps, canonical layout. Classic HAMT is a fallback only if CHAMP implementation hits a specific blocker.
38. **Performance is a first-class goal, not a v2 concern.** Tier 1 wins (§19.6) are baked into v1 by architecture. Tier 2 wins are committed Phase 6 targets with specific, named mechanisms. Headline performance claims are published only alongside v1 with measured benchmarks, not asserted in advance.

---

## 24. Open Questions (Deferred)

Deliberately unresolved. Each tracked so we don't drift into them accidentally.

1. **When does protocol support land?** After v1 is stable, driven by concrete user requests.
2. **Should `map` / `filter` / `reduce` be lazy or eager?** v1 = eager, returning vectors. A separate `stream` library may land in v2.
3. **Do we ever ship a `#inst`-style tagged literal?** Probably as a macro-based reader extension in v2, not a first-class reader feature.
4. **AOT compilation?** Out of scope. `.nx.o` files are bytecode only.
5. **Schema / spec language?** Likely a core feature in v2. Not v1.
6. **Content-addressed values for deduplication?** Specifically disallowed from v1 because it changes hash stability rules.
7. **Multi-version concurrency across isolates?** Depends on multi-isolate runtime; deferred.
8. **REPL-over-network (nREPL-style)?** Nice-to-have; deferred.
9. **Regex library integration**. Which regex engine (v1 bundled Zig-native vs. none)? Deferred.
10. **Record types with fixed fields and custom print.** v1 uses tagged maps; real records are a v2 feature. Remove `record` from the §8.2 heap-kinds list for v1 and treat it as a post-v1 addition.
11. **Keyword-as-function** (`(:foo m)` as sugar for `(get m :foo)`). Clojure has it; nexis v1 does not. Revisit once the core language has shipped.
12. **`io` and `simd` ISA groups.** Listed in §12.3 for future reservation, but v1 may implement their operations as ordinary native/core function calls rather than dedicated opcode groups. Decide during Phase 2 compiler bring-up whether a dedicated group pays off.

---

## 25. Risk Register

The things most likely to go wrong, with mitigations.

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | Semantic drift between Value, Form, and durable encoding as v1 grows | High | Severe | §5 is non-negotiable; review every new kind against all three layers. |
| 2 | GC bugs that corrupt heap under stress | High | Severe | Phase 1 gate's GC stress test; precise root enumeration; no write barriers in v1. |
| 3 | Equality/hash inconsistency between heap and decoded values | Medium | Severe | Phase 1 gate property test #5 explicitly checks round-trip hash preservation. |
| 4 | Transient ownership violations slipping through | Medium | Moderate | Runtime check on every op; property tests. |
| 5 | Macro expansion non-termination or stack overflow | Medium | Moderate | Expansion depth limit + clear error. |
| 6 | Tail-call elision breaking debuggability | Low | Moderate | `--emit-tailcall-report` flag; only emit tailcall where safe. |
| 7 | emdb API changes underneath us | Low | Moderate | Pinned version in `build.zig.zon`; our own tests catch regressions. |
| 8 | Zig 0.16 stdlib churn | Medium | Moderate | Pinned Zig version; `ZIG-0.16.0-REFERENCE.md` as authoritative. |
| 9 | Over-ambition in stdlib leading to shallow v1 | High | Moderate | §17 is the shipping list; things not on it don't ship. |
| 10 | Scope creep toward "Clojure compatibility" | Medium | Severe | §4 non-goals are doctrine, not wishes. |
| 11 | ~~RRB implementation complexity stalls Phase 1~~ **Mitigated**: v1 now ships plain 32-way persistent vector (matching Clojure); RRB is v2+. | — | — | Resolved by Clojure source review (§9.2). |
| 12 | **Codec serialization boundary creeps** (functions, vars, records sneak in) | High | Severe | §15.10 lists exactly what's serializable; anything else throws `:unserializable`. Amendment required to add a kind. |
| 13 | **Numeric corner cases poison eq/hash/codec** (NaN, −0, fixnum↔bignum promotion, f64↔int equality) | Medium | Severe | Phase 0 deliverable: `docs/SEMANTICS.md` freezes every numeric edge case before Phase 1 eq/hash code. |
| 14 | **Macro-expansion provenance inadequate for good errors** | Medium | Moderate | `Form.ann` is inline and carries expansion parent; validate in Phase 3 with tests that errors inside macros point at both expansion and definition sites. |
| 15 | **Durable-ref consistency surprises outside tx** (two `@r` in the same `let` may see different snapshots) | Medium | Moderate | §15.3 warns explicitly; stdlib provides `with-read-tx` and `db/as-of`; docs push snapshot scopes as the default. |
| 16 | **Intern table grows unbounded in long-lived REPL sessions** | Low | Moderate | Monitor in Phase 5 tooling; consider weak-intern semantics or manual `unintern` in v2. |
| 17 | **emdb snapshot pinning causes apparent leaks** (user holds a `db/snapshot` and file grows) | Medium | Moderate | `db/snapshot-stats` in Phase 5 exposes pinned snapshots; REPL warns on long-held snapshots. |

---

## 26. Appendix A — Comparison With Clojure

| Aspect | Clojure | nexis v1 |
|---|---|---|
| Host | JVM | Native (Zig) |
| Values | Heap objects + primitive boxes | 16-byte tagged Value |
| Collections | HAMT, persistent vector | HAMT/CHAMP, RRB tree |
| Numbers | int, long, BigInteger, BigDecimal, Ratio, double | fixnum, bignum, f64 only |
| `(= 1 1.0)` | true | **false** (use `==` for cross-type) |
| Laziness | Pervasive `seq` | Eager, explicit streams later |
| STM | `ref`, `dosync`, `alter` | **Removed.** emdb transactions only |
| Atoms | In-memory CAS | **Removed.** Durable refs are different |
| Agents | `send`, `send-off` | **Removed.** |
| `core.async` | Channels, go blocks | **Removed.** |
| Multimethods | `defmulti`, `defmethod` | **Removed.** |
| Protocols | `defprotocol`, `extend-type` | **Removed in v1.** |
| Reader conditionals | `#?(...)` | **Removed.** |
| Tagged literals | `#inst`, `#uuid`, user-extensible | **Removed.** |
| Namespaces | `ns`, `require`, `refer`, `alias` | **Kept.** Simplified. |
| Vars | Interned, dynamic-capable | **Kept.** Simplified, `^:dynamic` opt-in |
| Keywords | Interned, invokable | **Kept.** |
| Destructuring | Vec + map patterns | **Kept.** v1 covers common cases |
| Threading macros | `->`, `->>`, `cond->`, `some->` | **Kept.** |
| Metadata | Non-equality-affecting | **Kept.** Identical semantics |
| Syntax-quote | Full hygiene-ish, auto-gensym | **Kept.** Auto-gensym only; no full hygiene |
| REPL redefinition | Through Vars | **Kept.** |
| Storage integration | JDBC / external libraries | **New.** First-class emdb durable refs |
| Historical reads | Not standard | **Later.** Architecture allows it |
| Transactions | STM or external | **New.** emdb transactions are the language tx |

---

## 27. Appendix B — Worked Examples

### 27.1 Hello, world

```clojure
(println "hello, world")
```

### 27.2 A function with multi-arity

```clojure
(defn greet
  ([] (greet "world"))
  ([who] (str "hello, " who)))

(greet)           ; => "hello, world"
(greet "nexis")   ; => "hello, nexis"
```

### 27.3 Persistent update

```clojure
(def alice {:name "alice" :age 30})
(def alice-older (update alice :age inc))

alice        ; => {:name "alice", :age 30}      original unchanged
alice-older  ; => {:name "alice", :age 31}
```

### 27.4 A macro

```clojure
(defmacro unless [pred & body]
  `(if ~pred nil (do ~@body)))

(unless false
  (println "this prints"))
```

### 27.5 Transactional durable state

```clojure
(def conn (db/open "app.edb"))
(def alice (db/ref conn :users "alice"))

(with-tx [tx conn]
  (db/put! tx alice {:name "alice" :age 30}))

@alice
;; => {:name "alice", :age 30}

(with-tx [tx conn]
  (db/alter! tx alice update :age inc))

@alice
;; => {:name "alice", :age 31}
```

### 27.6 Scanning a tree

```clojure
(with-read-tx [tx conn]
  (reduce
    (fn [acc [k v]] (conj acc v))
    []
    (db/scan tx :users nil nil)))
;; => [{:name "alice", :age 31} {:name "bob", :age 27} ...]
```

### 27.7 Typed vector + SIMD

```clojure
(require '[nexis.simd :as simd])

(def xs (simd/f64-vector [1.0 2.0 3.0 4.0]))
(def ys (simd/f64-vector [0.5 0.5 0.5 0.5]))

(simd/vdot xs ys)    ; => 5.0
```

### 27.8 A loop with `recur`

```clojure
(defn sum-to [n]
  (loop [i 0 acc 0]
    (if (> i n)
      acc
      (recur (inc i) (+ acc i)))))

(sum-to 100)   ; => 5050
```

### 27.9 Tap-based REPL debugging

```clojure
(->> (range 10)
     (map inc)
     (tap>)           ; sends intermediate value to inspector
     (filter even?)
     (reduce +))
;; => 30
```

### 27.10 Redefining at the REPL

```clojure
user=> (defn f [x] (* x 2))
#'user/f
user=> (def g (fn [x] (f (inc x))))
#'user/g
user=> (g 5)
12
user=> (defn f [x] (* x 10))   ; redefine f
#'user/f
user=> (g 5)                   ; g sees new f on next call
60
```

---

## 28. Appendix C — Canonical Form Schema

**The single most important artifact for Phase 0 implementation.** This is the authoritative contract between the `nexis.grammar` parser output and the `src/reader.zig` Form tree that macros/compiler consume.

### 28.1 Form shape

A `Form` is a recursive heap-resident wrapper:

```zig
pub const Form = struct {
    datum: Datum,                // see §28.2
    origin: ?SrcSpan,            // { file_id: u32, pos: u32, len: u16 }
    user_meta: ?*PersistentMap,  // user-attached via `^:kw`, `^{...}`, `^sym`
    ann: ?*Annotation,           // compiler-injected: macro provenance, resolved ns/sym info
};
```

- `datum` is the form's actual content (atom or compound).
- `origin` comes from the parser's `Sexp.src`.
- `user_meta` is always a normalized map (reader converts `^:kw` → `{:kw true}` before attaching).
- `ann` is invisible to user code; the compiler writes to it, user code can only observe `user_meta` via `(meta x)`.

### 28.2 Canonical datum shapes

```
;; Atoms (leaves; Form's datum is an Atom variant)
nil                                  ;; nil
true, false                          ;; bool
42, 0x2A, 0b101                      ;; int (normalized from any radix)
3.14, 1e9, 1.5e-3                    ;; real (f64)
"hello"                              ;; string
\a, \newline, \u{2603}               ;; char (Unicode scalar)
:foo, :ns/foo                        ;; keyword (interned, no metadata)
foo, ns/foo, set!, ->>               ;; symbol

;; Compounds (Form's datum is a Compound variant with a tag + children)
(list   f1 f2 f3)                    ;; (...)
(vector f1 f2 f3)                    ;; [...]
(map    k1 v1 k2 v2)                 ;; {...}  — flat key/value alternation
(set    f1 f2 f3)                    ;; #{...}

;; Reader macros (user-visible conventional tags)
(quote             f)                ;; 'f
(syntax-quote      f)                ;; `f
(unquote           f)                ;; ~f
(unquote-splicing  f)                ;; ~@f
(deref             f)                ;; @f

;; Metadata
(with-meta TARGET META-MAP)          ;; ^meta x  —  META-MAP-first-in-source, TARGET-first-in-Form

;; Internal-only (reader-normalizer output; not user-addressable names)
(#%anon-fn f1 f2 ...)                ;; #(...) body, lowered post-parse but pre-macroexpand
```

### 28.3 Reader-normalization rules (authoritative)

These transformations happen between the raw `Sexp` parser output and the `Form` tree that macros see. They are part of the reader/normalizer stage, **before** macroexpansion.

| Source | Canonical Form |
|---|---|
| `^:kw x` | `(with-meta x {:kw true})` |
| `^{:a 1} x` | `(with-meta x {:a 1})` |
| `^sym x` | `(with-meta x {:tag sym})` |
| `#_ x y` | the `x` form is discarded; only `y` appears in output |
| `#(body)` | `(#%anon-fn body)` — `%`/`%1`/`%2`/`%&` left as ordinary symbols; macro-stage pass later resolves to a `(fn* [...] body)` |
| `` `x `` | `(syntax-quote x)` — Clojure-equivalent expansion is a *separate* post-parse pass, NOT done by the reader |
| `{:a 1 :a 2}` | **reader-normalization ERROR**: `:duplicate-literal-key :a` (statically detected) |
| `{:a}` | **reader ERROR**: `:map-odd-count` |
| `#{1 1 2}` | **reader-normalization ERROR**: `:duplicate-literal-element 1` |
| `#(#(inc %))` | **reader-normalization ERROR**: `:nested-anon-fn` |
| `~@x` outside `` `...` `` | **reader-normalization ERROR**: `:unquote-splice-outside-syntax-quote` |

### 28.4 Stage ownership (who does what)

A fresh implementation session **must** respect these stage boundaries:

| Stage | Input | Output | Responsibilities |
|---|---|---|---|
| **Parser** (nexus-generated, `src/parser.zig`) | source text | raw `Sexp` tree with `.src` spans | Tokenization + LALR(1) parse. No semantic validation beyond grammar. No normalization. |
| **Reader / normalizer** (`src/reader.zig`) | raw `Sexp` | canonical `Form` tree | Wraps each Sexp into a Form. Attaches source spans. Normalizes metadata sugar → map form. Lowers `#(...)` → `(#%anon-fn ...)`. Emits `(syntax-quote f)` markers. Discards `#_` forms. Rejects duplicate literal keys / odd map arity / nested anon-fn / bare unquote. |
| **Macroexpander** (`src/macroexpand.zig`) | canonical `Form` | expanded `Form` | Expands macros to fixpoint. Expands `syntax-quote` forms (auto-qualifies symbols, auto-gensym `x#`, handles unquote/splice). Resolves `#%anon-fn` to `(fn* [%1 %2 ...] body)`. Passes `&form` and `&env` to user macros. |
| **Resolver** (`src/resolve.zig`) | expanded `Form` | `Resolved` AST | Symbols → slot / upvalue / var handle / special form. Errors on unbound. |

**Important**: `syntax-quote` expansion happens in the **macroexpander**, not the reader. The reader only marks syntax-quoted forms with the `(syntax-quote f)` tag. This lets tooling inspect raw reader output without losing the backtick-form structure.

### 28.5 Worked examples (source → canonical Form)

#### Example 1 — simple metadata

```
Source:      ^:private (defn foo [x] x)
Form:        (with-meta (list (sym defn) (sym foo) (vector (sym x)) (sym x)) {:private true})
```

#### Example 2 — nested metadata

```
Source:      ^:dynamic ^{:doc "a var"} *out*
Form:        (with-meta (sym *out*) {:dynamic true, :doc "a var"})
```

Reader merges multiple metadata annotations into a single map. Rightmost wins on duplicate keys, matching Clojure.

#### Example 3 — syntax-quote with unquote

```
Source:      `(if ~cond :yes :no)
Form:        (syntax-quote (list (sym if) (unquote (sym cond)) (keyword :yes) (keyword :no)))
```

Note the `syntax-quote` is a structural marker. The macroexpander later rewrites this to the Clojure-equivalent `(seq (concat (list (quote nexis.core/if)) (list cond) (list :yes) (list :no)))`.

#### Example 4 — anonymous function

```
Source:      #(+ %1 %2)
Form:        (#%anon-fn (list (sym +) (sym %1) (sym %2)))
```

The `%1`, `%2` are ordinary symbols at this stage. The macroexpander rewrites `#%anon-fn` to `(fn* [%1 %2] body)` after scanning the body for positional-arg references.

#### Example 5 — collection literal with keyword keys

```
Source:      {:a 1 :b 2}
Form:        (map (keyword :a) (int 1) (keyword :b) (int 2))
```

Flat key/value alternation. Odd counts rejected at the reader. Duplicate literal keys (`{:a 1 :a 2}`) rejected at the reader.

#### Example 6 — discard

```
Source:      (+ #_(expensive-thing) 1 2)
Form:        (list (sym +) (int 1) (int 2))
```

The `#_` form is completely absent from the output.

#### Example 7 — deref sugar

```
Source:      @some-ref
Form:        (deref (sym some-ref))
```

#### Example 8 — char literals

```
Source:      [\a \newline \u{2603}]
Form:        (vector (char 'a') (char '\n') (char 0x2603))
```

Character `datum` stores the Unicode scalar value directly.

#### Example 9 — quote vs syntax-quote

```
Source A:    'foo
Form A:      (quote (sym foo))

Source B:    `foo
Form B:      (syntax-quote (sym foo))
```

`quote` and `syntax-quote` are distinct Form tags — not the same node type with a flag. Separate handling throughout compiler.

#### Example 10 — negative integer literal

```
Source:      (+ -1 2)
Form:        (list (sym +) (int -1) (int 2))
```

The reader parses `-1` as a numeric literal, not as `(- 1)`. Grammar rule: a digit immediately following `-` with no intervening whitespace and `-` in token-start position produces a negative-number token.

### 28.6 Golden test contract

`test/golden/reader-literals.{nx,sexp}` MUST pass byte-for-byte. A diff against the expected `.sexp` output is a reader regression. This file is the authoritative executable specification of the schema in §28.2–§28.3.

---

## Final Word

**Be less ambitious in representation unification, and more ambitious in semantic clarity.**

If nexis v1 ships a clean Lisp with persistent collections and an elegant explicit-transaction durable-identity model, it is already differentiated from every Lisp that came before it. Everything beyond that is a post-v1 conversation.

The project succeeds if nexis feels like:

- a clean, sharp Lisp,
- with excellent immutable data structures,
- plus an explicit and elegant durable identity model.

It fails if it feels like:

- a Clojure clone with a bespoke VM,
- or a DB runtime with Lisp syntax,
- or a research pile where heap and storage semantics are half-merged.

**Ship the smallest coherent thing. Then iterate.**

---

*Document version: 1.1 — Finalized after exhaustive Clojure source review and 8 rounds of peer-AI (GPT-5.4) adversarial critique. Ready to drive Phase 0 implementation.*

*Companion documents: `CLOJURE-REVIEW.md` (source review findings), `docs/SEMANTICS.md` (Phase 0 deliverable — numeric corner cases, nil/empty semantics, print contract), `docs/FORMS.md` (Phase 0 deliverable — canonical Form schema).*

*Last updated: 2026-04-19*
