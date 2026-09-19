# Tests

nexis test coverage is split across three locations. **Most unit tests
live inline in `src/*.zig`** as Zig `test "..."` blocks — that is the
convention; there is no `test/unit/`.

## Layout

| Path | What | Run via |
|---|---|---|
| `src/*.zig` (inline `test` blocks) | Per-module unit tests + integration smoke tests | `zig build test` |
| `test/prop/` | Cross-module property tests (15 files: primitive, intern, heap, string, list, bignum, vector, champ, transient, gc, codec, db, compile, nextomic_key, nextomic_tx) | `zig build test` (`compile`, `nextomic_key` and `nextomic_tx` also via `zig build quick`) |
| `test/golden/` | Reader golden tests (`.nx` source ↔ `.sexp` / `.err` expected) | `zig build golden` (or `zig build test`) |
| `test/nextomic/` | Nextomic end-to-end scripts (`.nx` run through `bin/nexis` ↔ `.out` expected stdout) from a scratch directory that also holds `prelude.nx` (shared `check`/`caught` and the partition constants); `persist-1`/`persist-2` share one store across two processes | `zig build nextomic-nx` (or `zig build test`) |
| `test/integration/` | End-to-end source-to-execution suites (`eval_pipeline.zig`), the Nextomic query corpus (`nextomic_q.zig`, checked against a naive evaluator) and pull corpus (`nextomic_pull.zig`, checked against `entity()` and `datoms(.vaet)`) | `zig build test` (Nextomic ones also via `zig build nextomic-test`) |
| `examples/` | Every example runs through `bin/nexis`; the store-backed ones twice | `zig build examples` (or `zig build test`) |
| `test/fuzz/` | Fuzz targets; populated as fuzzing lands | — |

## Two build steps for two loops

- **`zig build quick`** (seconds) — the language binaries (`vm`,
  `compile`, `expand`, `stdlib`, `loader`, `atom`, `record`,
  `protocol`, `format`), the compile property tests, the eval-pipeline
  integration tests and the Nextomic unit and property binaries. The
  inner edit/test loop. `zig build phase2-test` names the same step.
- **`zig build test`** (minutes) — the full suite: every module's
  inline tests, property tests, golden verification, the Nextomic
  corpora, the `.nx` scripts and the examples. The runtime is
  dominated by the randomized CHAMP correctness gate. Run before
  commits.

The two Nextomic corpora end with a benchmark whose row-count checks
always run; its `[bench]` timing lines print only when the
`NEXTOMIC_BENCH` environment variable is set (`docs/PERF.md` §3.7).

## Counts

`zig build test --summary all` prints the authoritative count
(`HANDOFF.md` §1 carries the number of record). Per-binary counts are
in the same summary.
