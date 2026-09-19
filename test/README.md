# Tests

nexis test coverage is split across three locations. **Most unit tests
live inline in `src/*.zig`** as Zig `test "..."` blocks — that is the
convention; there is no `test/unit/`.

## Layout

| Path | What | Run via |
|---|---|---|
| `src/*.zig` (inline `test` blocks) | Per-module unit tests + integration smoke tests | `zig build test` |
| `test/prop/` | Cross-module property tests (16 files: primitive, intern, heap, string, list, bignum, vector, champ, transient, typed_vector, gc, codec, db, compile, nextomic_key, nextomic_tx) | `zig build test` (`compile`, `nextomic_key` and `nextomic_tx` also via `zig build quick`) |
| `test/golden/` | Reader golden tests (`.nx` source ↔ `.sexp` / `.err` expected) | `zig build golden` (or `zig build test`) |
| `test/nextomic/` | Nextomic end-to-end scripts (`.nx` run through `bin/nexis` ↔ `.out` expected stdout) from a scratch directory that also holds `prelude.nx` (shared `check`/`caught` and the partition constants); `persist-1`/`persist-2` share one store across two processes | `zig build nextomic-nx` (or `zig build test`) |
| `test/integration/` | End-to-end source-to-execution suites (`eval_pipeline.zig`, `runtime_polish.zig`, `numbers.zig`), the Nextomic query corpus (`nextomic_q.zig`, checked against a naive evaluator), pull corpus (`nextomic_pull.zig`, checked against `entity()` and `datoms(.vaet)`), the shared fixture (`nextomic_fx.zig`), transaction functions and schema alteration (`nextomic_fn.zig`) and the lazy entity (`nextomic_entity.zig`) | `zig build test` (Nextomic ones also via `zig build nextomic-test`) |
| `examples/` | Every example runs through `bin/nexis`; the store-backed ones twice | `zig build examples` (or `zig build test`) |
| `test/fuzz/` | Empty: the targets its README names have no harness | — |

## Two build steps for two loops

- **`zig build quick`** (seconds) — the language binaries (`vm`,
  `compile`, `expand`, `stdlib`, `loader`, `disasm`, `atom`, `record`,
  `protocol`, `format`), the compile property tests, the
  `eval_pipeline`, `runtime_polish` and `numbers` integration tests
  and the Nextomic unit and property binaries. The inner edit/test
  loop.
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
(`HANDOFF.md` §2 carries the number of record). Per-binary counts are
in the same summary.
