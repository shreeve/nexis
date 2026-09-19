# nexis docs map

This directory holds the design specifications for nexis. Each spec is
authoritative for the contract of its corresponding source module(s).
Implementation must conform to the spec; if conflict arises, the spec
wins and the code is wrong.

## Module ↔ spec correspondence

| Source module | Spec | Notes |
|---|---|---|
| `src/value.zig` | [`VALUE.md`](VALUE.md) | 16-byte tagged Value layout + Kind discriminator |
| `src/heap.zig` | [`HEAP.md`](HEAP.md) | HeapHeader format + Heap allocator wrapper |
| `src/intern.zig` | [`INTERN.md`](INTERN.md) | Symbol + keyword interning + Name split |
| `src/string.zig` | [`STRING.md`](STRING.md) | String heap kind |
| `src/bignum.zig` | [`BIGNUM.md`](BIGNUM.md) | Bignum canonicalization, arithmetic, ordering, conversion, decimal text |
| `src/coll/list.zig` | [`LIST.md`](LIST.md) | Immutable cons list |
| `src/coll/champ.zig` | [`CHAMP.md`](CHAMP.md) | Persistent map + set via CHAMP (Compressed Hash-Array Mapped Prefix-tree) |
| `src/coll/vector.zig` | [`VECTOR.md`](VECTOR.md) | Persistent vector: 32-way trie with a tail |
| `src/coll/transient.zig` | [`TRANSIENT.md`](TRANSIENT.md) | Transient lifecycle + ownership |
| `src/coll/typed_vector.zig` | [`TYPED_VECTOR.md`](TYPED_VECTOR.md) | Typed vector: unboxed i64 / f64 elements, codec, `nexis.simd` kernels |
| `src/eq.zig` | (in [`SEMANTICS.md`](SEMANTICS.md) §2) | Equality predicates; no dedicated spec doc |
| `src/hash.zig` | (in [`SEMANTICS.md`](SEMANTICS.md) §3) | Hash primitives; no dedicated spec doc |
| `src/dispatch.zig` | (no dedicated spec) | Cross-kind sequential equality/hash terminal — implementation detail, contract lives in the per-kind specs |
| `src/gc.zig` | [`GC.md`](GC.md) | Precise mark-sweep tracing GC |
| `src/codec.zig` | [`CODEC.md`](CODEC.md) | Wire-format serialization |
| `src/db.zig` | [`DB.md`](DB.md) | emdb-backed durable storage integration |
| `src/pool.zig` | [`POOL.md`](POOL.md) | Small-object pool allocator |
| `src/bench.zig` | [`BENCH.md`](BENCH.md) | Benchmark harness |
| `src/reader.zig` | [`FORMS.md`](FORMS.md) | Sexp → Form normalizer + pretty-printer + canonical Form schema |
| `src/vm.zig` | [`VM.md`](VM.md) | Bytecode VM: ISA + execution contracts, frames, handlers, natives, namespaces |
| `src/compile.zig` | [`COMPILER.md`](COMPILER.md) | Compiler: Form → Tiny → bytecode, per-special-form lowering, capture analysis |
| `src/cli.zig` | [`TOOLING.md`](TOOLING.md) §1 | CLI runner — `nexis run FILE.nx` / `nexis repl` / `nexis disasm FILE.nx`; wires the pipeline into `bin/nexis`; runtime error output |
| `src/disasm.zig` | [`TOOLING.md`](TOOLING.md) §2 | Bytecode disassembler behind `nexis disasm` |
| `src/expand.zig` | [`MACROEXPAND.md`](MACROEXPAND.md) | Form → Form rewriter (macros, syntax-quote, anon-fn, `#%list`/`#%concat`/`#%vector` dispatch); host-Zig macros and user `defmacro` |
| `src/atom.zig` | [`ATOM.md`](ATOM.md) | In-memory mutable cells: `atom` / `swap!` / `reset!` / `compare-and-set!` |
| `src/protocol.zig`, `src/record.zig` | [`PROTOCOLS.md`](PROTOCOLS.md) | Records + protocols: per-VM registries, `defrecord` / `defprotocol` / `extend-*` dispatch |
| `src/loader.zig` | (in [`MACROEXPAND.md`](MACROEXPAND.md) §2b) | `(require ...)` file loading: ns-to-path mapping, load path, cycle detection |
| `src/stdlib.zig`, `src/stdlib/*.nx` | [`TOOLING.md`](TOOLING.md) §3–§4 for `test.nx`, `pprint.nx`, `math.nx` | Native functions + the embedded `nexis.core` / `nextomic` / `nexis.test` / `nexis.pprint` / `nexis.math` sources |
| `src/format.zig` | (in [`STRING.md`](STRING.md) §9) | Value printing (`pr-str` / `str` modes) |
| `src/nextomic/*` | [`NEXTOMIC.md`](NEXTOMIC.md) | The database: store layout, transactions, db-values and time, query pipeline, pull, Lisp API, errors |
| `src/parser.zig` | (no dedicated spec) | **Generated** from `nexis.grammar` by the external `nexus` tool. Do not edit by hand. |
| `src/nexis.zig` | (no dedicated spec) | `@lang` module — Tag enum + Lexer wrapper |
| `src/golden.zig` | (no dedicated spec) | Build tooling — golden-test runner CLI |

## Cross-cutting specs

These specs are not 1:1 with a single source module — they span multiple
modules and pin contracts that several modules must conform to.

| Spec | Scope |
|---|---|
| [`SEMANTICS.md`](SEMANTICS.md) | Equality, hash, numeric corner cases — pins the contract that `value.zig`, `eq.zig`, `hash.zig`, `dispatch.zig` collectively implement |
| [`PERF.md`](PERF.md) | Performance methodology + gates — what the bench harness measures and what's a regression |
| [`NEXTOMIC.md`](NEXTOMIC.md) | Nextomic: the Datomic-class database on nexis + emdb — storage layout, transactions, db-values and time, the query pipeline, the Lisp API (authoritative; the code follows it) |

## Top-level docs (not in `docs/`)

These are governance / meta docs and live at the repository root:

| Doc | Purpose |
|---|---|
| [`PLAN.md`](../PLAN.md) | Authoritative design spec — read first; §23 frozen decisions are binding |
| [`AGENTS.md`](../AGENTS.md) | Routing guide for contributors + AI sessions |
| [`HANDOFF.md`](../HANDOFF.md) | The guide for a new session: what exists, how to verify it, how to work here, known gaps |
| [`CLOJURE-REVIEW.md`](../CLOJURE-REVIEW.md) | What we take / adapt / reject from Clojure's source |
| [`README.md`](../README.md) | Short project pitch + status |
| [`ZIG-0.16.0.md`](../ZIG-0.16.0.md) | Project-specific Zig 0.16 stdlib reference + gotchas |

## Reading order

If you're new to the project, read in this order (per AGENTS.md §"Required reading"):

1. `PLAN.md` end-to-end (~75 min). Especially §5 (three representations), §23 (frozen decisions), §24 (open questions), Appendix C / §28 (canonical Form schema).
2. `CLOJURE-REVIEW.md` — what we take from Clojure and why.
3. `docs/FORMS.md` — the Form schema you'll be reading + producing.
4. `docs/SEMANTICS.md` — equality/hash/numeric edge cases (frozen).
5. `docs/CODEC.md` — serialization scope (frozen).
6. `docs/NEXTOMIC.md` — before touching `src/nextomic/` or the `nextomic` namespace.
7. `ZIG-0.16.0.md` + `AGENTS.md` before writing any Zig.

For compiler or VM work: `docs/MACROEXPAND.md`, `docs/COMPILER.md` and `docs/VM.md` are the authoritative contracts.

## Spec discipline (per AGENTS.md "Authority order")

When sources disagree:

1. `PLAN.md` §23 frozen decisions — highest authority.
2. `PLAN.md` Appendix C (§28) canonical schema.
3. `docs/*.md` — derivative; must track `PLAN.md`.
4. Code comments — lowest. If code says one thing and `PLAN.md` says another, `PLAN.md` wins and the code is wrong.

Every doc describes the module as it is. Where a doc states an absence ("`byte_vector` has no implementation"), that absence is a fact about the tree, not a schedule; `PLAN.md` §21 and `HANDOFF.md` §4 hold the roadmap.
