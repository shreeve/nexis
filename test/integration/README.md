# test/integration

End-to-end suites that run source through the whole pipeline
(`.nx` text → reader → Form → macroexpansion → bytecode → VM → result)
and Nextomic through its public Zig API:

- `eval_pipeline.zig`: every primitive core form, every macro, every
  try/catch/finally path, VM stack discipline across nested calls
  (each run asserts the stack length and frame depth are restored).
- `nextomic_q.zig`: the Datalog corpus; every query is checked against
  a naive evaluator over `DbValue.datoms`.
- `nextomic_pull.zig`: the pull corpus, checked against `entity()`.

Run with `zig build test`; the Nextomic suites also run under
`zig build nextomic-test`. Language-level scripts live in
`test/nextomic/*.nx` (run by `zig build nextomic-nx`).
