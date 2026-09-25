# Tests

nexis test coverage is split across three locations. **Most unit tests
live inline in `src/*.zig`** as Zig `test "..."` blocks — that is the
convention; there is no `test/unit/`.

## Layout

| Path | What | Run via |
|---|---|---|
| `src/**/*.zig` (inline `test` blocks) | Per-module unit tests, compiled into one `unit` binary rooted at `src/root.zig` (a file's tests run once `src/root.zig` declares it; the build's layering check rejects an undeclared file) | `zig build test`, `zig build quick` |
| `test/prop/` | Cross-module property tests (16 files: primitive, intern, heap, string, list, bignum, vector, champ, transient, typed_vector, gc, codec, db, compile, nextomic_key, nextomic_tx) | `zig build test` (`compile`, `nextomic_key` and `nextomic_tx` also via `zig build quick`) |
| `test/golden/` | Reader golden tests (`.nx` source ↔ `.sexp` / `.err` expected) | `zig build golden` (or `zig build test`) |
| `test/nextomic/` | Nextomic end-to-end scripts (`.nx` run through `bin/nexis` ↔ `.out` expected stdout) from a scratch directory that also holds `prelude.nx` (shared `check`/`caught` and the partition constants); `persist-1`/`persist-2` share one store across two processes | `zig build nextomic-nx` (or `zig build test`) |
| `test/integration/` | End-to-end source-to-execution suites (`eval_pipeline.zig`, `runtime_polish.zig`, `numbers.zig`), the Nextomic query corpus (`nextomic_q.zig`, checked against a naive evaluator), pull corpus (`nextomic_pull.zig`, checked against `entity()` and `datoms(.vaet)`), the shared fixture (`nextomic_fx.zig`), transaction functions and schema alteration (`nextomic_fn.zig`) and the lazy entity (`nextomic_entity.zig`) | `zig build test` (Nextomic ones also via `zig build nextomic-test`) |
| `examples/` | Every example runs through `bin/nexis`; the store-backed ones twice | `zig build examples` (or `zig build test`) |
| `test/fuzz/` | Empty: the targets its README names have no harness | — |

Property and integration files import the runtime as one module:
`const nx = @import("nexis");` then `nx.vm`, `nx.nextomic` and so on.
`test/harness.zig` (module `harness`) is the pipeline harness they
share: `Program` boots a VM the way `bin/nexis` does (every namespace,
every embedded source), `expectOutput` / `expectCheckedOutput` /
`expectError` run one program per assertion, and `Store` names a
store under the test's own temporary directory. Each program's
allocator is leak-checked without per-allocation stack traces, so a
fresh VM per assertion costs milliseconds and a leak still fails the
test.

## Two build steps for two loops

- **`zig build quick`** — the `unit` binary (every inline test), the
  compile and Nextomic property tests and the `eval_pipeline`,
  `runtime_polish` and `numbers` integration tests. The inner
  edit/test loop.
- **`zig build test`** (minutes) — the full suite: the `unit` binary,
  every property test, golden verification, the Nextomic
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
