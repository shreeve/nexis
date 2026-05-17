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
| `src/bignum.zig` | [`BIGNUM.md`](BIGNUM.md) | Bignum semantics + canonicalization |
| `src/coll/list.zig` | [`LIST.md`](LIST.md) | Immutable cons list |
| `src/coll/champ.zig` | [`CHAMP.md`](CHAMP.md) | Persistent map + set via CHAMP (Compressed Hash-Array Mapped Prefix-tree) |
| `src/coll/vector.zig` | [`VECTOR.md`](VECTOR.md) | Persistent vector via RRB tree |
| `src/coll/transient.zig` | [`TRANSIENT.md`](TRANSIENT.md) | Transient lifecycle + ownership |
| `src/eq.zig` | (in [`SEMANTICS.md`](SEMANTICS.md) §2) | Equality predicates; no dedicated spec doc |
| `src/hash.zig` | (in [`SEMANTICS.md`](SEMANTICS.md) §3) | Hash primitives; no dedicated spec doc |
| `src/dispatch.zig` | (no dedicated spec) | Cross-kind sequential equality/hash terminal — implementation detail, contract lives in the per-kind specs |
| `src/gc.zig` | [`GC.md`](GC.md) | Precise mark-sweep tracing GC |
| `src/codec.zig` | [`CODEC.md`](CODEC.md) | Wire-format serialization |
| `src/db.zig` | [`DB.md`](DB.md) | emdb-backed durable storage integration |
| `src/pool.zig` | [`POOL.md`](POOL.md) | Small-object pool allocator |
| `src/bench.zig` | [`BENCH.md`](BENCH.md) | Benchmark harness |
| `src/reader.zig` | [`FORMS.md`](FORMS.md) | Sexp → Form normalizer + pretty-printer + canonical Form schema |
| `src/vm.zig` | [`VM.md`](VM.md) | Phase 2 bytecode VM: ISA + execution contracts |
| `src/compile.zig` | [`COMPILER.md`](COMPILER.md) | Phase 2 compiler: pipeline + per-special-form lowering |
| `src/cli.zig` | (no dedicated spec) | Step H1 CLI runner — wires the pipeline into `bin/nexis` |
| `src/macroexpand.zig` (Phase 2 step #8) | [`MACROEXPAND.md`](MACROEXPAND.md) | Form → Form rewriter; host-Zig macros for v1 (`defmacro` defers to Phase 3) |
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
| [`NEXTOMIC.md`](NEXTOMIC.md) | Post-v1 Datomic-class database architecture on nexis + emdb — NOT a v1 deliverable, but constrains v1 substrate decisions |

## Top-level docs (not in `docs/`)

These are governance / meta docs and live at the repository root:

| Doc | Purpose |
|---|---|
| [`PLAN.md`](../PLAN.md) | Authoritative design spec — read first; §23 frozen decisions are binding |
| [`AGENTS.md`](../AGENTS.md) | Routing guide for contributors + AI sessions |
| [`HANDOFF.md`](../HANDOFF.md) | Inter-session handoff prompt — current state + next task |
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
6. `docs/NEXTOMIC.md` — only if Nextomic is being scoped OR a v1 decision might preclude it.
7. `ZIG-0.16.0.md` + `AGENTS.md` before writing any Zig.

For Phase 2 work specifically: `docs/VM.md` and `docs/COMPILER.md` are the authoritative contracts.

## Spec discipline (per AGENTS.md "Authority order")

When sources disagree:

1. `PLAN.md` §23 frozen decisions — highest authority.
2. `PLAN.md` Appendix C (§28) canonical schema.
3. `docs/*.md` — derivative; must track `PLAN.md`.
4. Code comments — lowest. If code says one thing and `PLAN.md` says another, `PLAN.md` wins and the code is wrong.

Amendment log entries at the bottom of `VM.md` and `COMPILER.md` track every spec evolution with the peer-AI conversation turn that prompted it.
