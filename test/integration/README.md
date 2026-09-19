# test/integration

End-to-end suites that run source through the whole pipeline
(`.nx` text → reader → Form → macroexpansion → bytecode → VM → result)
and Nextomic through its public Zig API:

- `eval_pipeline.zig`: every primitive core form, every macro, every
  try/catch/finally path, VM stack discipline across nested calls
  (each run asserts the stack length and frame depth are restored),
  and the `db/*` seam; each store-backed test opens its own store
  under `.zig-cache/tmp/` and deletes it.
- `runtime_polish.zig`: the Clojure-fidelity rules of the sequence
  library, records as maps and the uncaught-throw policy.
- `numbers.zig`: the numeric tower end to end — promotion at ±2^47
  and demotion back, contagion, literals and printing, predicates,
  `long`/`double`, and bignums through the codec.
- `nextomic_q.zig`: the Datalog corpus; every query is checked against
  a naive evaluator over `DbValue.datoms` and a hand-pinned row count.
- `nextomic_pull.zig`: the pull corpus, checked against `entity()` and
  `datoms(.vaet)`; also speculative `with` through `q`, `entity` and
  `pull`.

Both Nextomic corpora end with a benchmark over ~200k datoms whose
row-count checks always run; the `[bench]` timing lines print to
stderr only when the `NEXTOMIC_BENCH` environment variable is set
(`docs/PERF.md` §3.7 has the ReleaseFast numbers).

Run with `zig build test`; `eval_pipeline`, `runtime_polish` and
`numbers` also run under `zig build quick` and the Nextomic suites under
`zig build nextomic-test`. Language-level scripts live in
`test/nextomic/*.nx` (run by `zig build nextomic-nx`).
