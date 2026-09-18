# Tests

nexis test coverage is split across three locations. **Most unit tests
live inline in `src/*.zig`** as Zig `test "..."` blocks — that is the
convention. Don't look for them under `test/unit/` (intentionally not
present; see "removed directories" below).

## Layout

| Path | What | Run via |
|---|---|---|
| `src/*.zig` (inline `test` blocks) | Per-module unit tests + integration smoke tests | `zig build test` |
| `test/prop/` | Cross-module property tests (12 files: primitive, intern, heap, string, list, bignum, vector, hamt, transient, gc, codec, db) | `zig build test` |
| `test/golden/` | Phase 0 reader golden tests (`.nx` source ↔ `.sexp` / `.err` expected) | `zig build golden` (or `zig build test`) |
| `test/nextomic/` | Nextomic end-to-end scripts (`.nx` run through `bin/nexis` ↔ `.out` expected stdout), in a scratch directory, in order; `persist-1`/`persist-2` share one store across two processes | `zig build nextomic-nx` (or `zig build test`) |
| `test/integration/` | End-to-end source-to-execution suites (`eval_pipeline.zig`), the Nextomic query corpus (`nextomic_q.zig`, checked against a naive evaluator) and pull corpus (`nextomic_pull.zig`) | `zig build test` (Nextomic ones also via `zig build nextomic-test`) |
| `test/fuzz/` | Fuzz targets; populated as fuzzing lands | — |

## Two build steps for two loops

- **`zig build phase2-test`** (~3 seconds) — runs the `vm`, `compile`, integration and
  nextomic module tests. The inner edit/test loop for compiler/VM work.
- **`zig build test`** (~3 minutes) — runs the full suite: every module's
  inline tests, property tests, golden verification, the Nextomic
  corpora and the `.nx` scripts. The runtime is dominated by the
  randomized HAMT correctness gate. Run before commits.

## Counts

`zig build test --summary all` prints the authoritative count (1265 tests across 111 steps at the docs reconciliation). Per-binary counts are in the same summary.

## Removed directories

`test/unit/` and `test/bench/` previously existed as empty placeholders.
Both were removed for clarity:

- `test/unit/` contradicted the inline-test convention (new contributors
  would look there for unit tests and find them missing).
- `test/bench/` was empty; benchmark code lives in `bench/` (project
  root) and benchmark data in `bench/baseline*.json`.
