# Tests

Most unit tests live inline in `src/**/*.zig` as `test "..."` blocks;
the directories below hold what crosses modules.

## Layout

| Path | What | Run via |
|---|---|---|
| `src/**/*.zig` (inline `test` blocks) | Per-module unit tests, compiled into one `unit` binary rooted at `src/root.zig` (a file's tests run once `src/root.zig` declares it; the build's layering check rejects an undeclared file) | `zig build test`, `zig build quick` |
| `test/prop/` | Cross-module property tests (16 files: primitive, intern, heap, string, list, bignum, vector, champ, transient, typed_vector, gc, codec, db, compile, nextomic_key, nextomic_tx) | `zig build test` (`compile`, `nextomic_key` and `nextomic_tx` also via `zig build quick`) |
| `test/golden/` | Reader goldens (`.nx` source ↔ `.sexp`, `errors/*.nx` ↔ `.err`) and CLI goldens (`cli/`: what `bin/nexis` prints for a runtime error, a reader error, a disassembly, a script, a REPL session and the usage errors, stream by stream, with the exit code) | `zig build golden` (or `zig build test`) |
| `test/nextomic/` | Nextomic end-to-end scripts (`.nx` run through `bin/nexis` ↔ `.out` expected stdout), each from a fresh directory that holds the stores it creates; `prelude.nx` (shared `check`/`caught` and the partition constants) is found beside the script; `<name>-1`/`<name>-2` share one directory, so `persist-2` reads the store `persist-1` wrote | `zig build nextomic-nx` (or `zig build test`) |
| `test/integration/` | End-to-end source-to-execution suites (`eval_pipeline.zig`, `runtime_polish.zig`, `numbers.zig`), the Nextomic query corpus (`nextomic_q.zig`, checked against a naive evaluator), pull corpus (`nextomic_pull.zig`, checked against `entity()` and `datoms(.vaet)`), the shared fixture (`nextomic_fx.zig`), transaction functions and schema alteration (`nextomic_fn.zig`) and the lazy entity (`nextomic_entity.zig`) | `zig build test` (Nextomic ones also via `zig build nextomic-test`) |
| `examples/`, `test/examples/` | Every `examples/*.nx` runs through `bin/nexis` from a fresh directory, its stdout pinned to `test/examples/<name>.out`; an example with a `<name>.2.out` runs a second time over the store the first left | `zig build examples` (or `zig build test`) |

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

Every expected-output file the gate compares (`.sexp`, `.err`,
`.out`, `.disasm`) is rewritten from the current binary by
`zig build test -Dupdate=true` (or the narrower `golden`, `examples`,
`nextomic-nx` steps); read the diff before committing it. A missing
expected file fails its step and names the flag.

A program run is cached on the contents of everything it reads: the
binary, the script, its expected output, the files it loads
(`prelude.nx`, every file under `examples/lib/`, `test/golden/cli/lib/`)
and its environment, which is empty but for `NEXIS_GC_STRESS` (always
set for `test/nextomic/`, passed through from the build's environment
elsewhere). A change to any of them re-runs it, in a directory emptied
that build. The two runs that share a store (`persist-1`/`persist-2`,
an example with a `.2.out`) both run on every build.

## Running

`AGENTS.md` lists the build steps: `zig build quick` is the inner
loop (the `unit` binary, the compile and Nextomic property tests, the
`eval_pipeline`, `runtime_polish` and `numbers` suites) and
`zig build test --summary all` the gate, whose summary line
(`HANDOFF.md` §2) is the count of record. Each property and
integration file is its own binary, so they run in parallel.
