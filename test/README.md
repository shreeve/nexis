# Tests

Most unit tests live inline in `src/**/*.zig` as `test "..."` blocks;
the directories below hold what crosses modules.

## Layout

| Path | What | Run via |
|---|---|---|
| `src/**/*.zig` (inline `test` blocks) | Per-module unit tests, compiled into one `unit` binary rooted at `src/root.zig` (a file's tests run once `src/root.zig` declares it; the build's layering check rejects an undeclared file) | `zig build test`, `zig build quick` |
| `test/prop/` | Cross-module property tests (primitive, intern, heap, string, list, bignum, vector, champ, sorted, transient, typed_vector, gc, codec, db, compile, nextomic_key, nextomic_tx) | `zig build test` (`compile`, `nextomic_key` and `nextomic_tx` also via `zig build quick`) |
| `test/golden/` | Reader goldens (`src/golden.zig` prints what the reader makes of each `.nx`: its Form program, pinned to `.sexp`, or for `errors/*.nx` the refusal, pinned to `.err`) and CLI goldens (`cli/`: what `bin/nexis` prints for a runtime error, a reader error, a disassembly, a script, a REPL session and the usage errors, stream by stream, with the exit code) | `zig build golden` (or `zig build test`) |
| `test/nextomic/` | Nextomic end-to-end scripts (`.nx` run through `bin/nexis` ↔ `.out` expected stdout), each from a fresh directory that holds the stores it creates; `prelude.nx` (shared `check`/`caught` and the partition constants) is found beside the script; `<name>-1`/`<name>-2` share one directory, so `persist-2` reads the store `persist-1` wrote | `zig build nextomic-nx` (or `zig build test`) |
| `test/integration/` | End-to-end source-to-execution suites (`eval_pipeline.zig`, `runtime_polish.zig`, `numbers.zig`), the Nextomic query corpus (`nextomic_q.zig`, checked against a naive evaluator), pull corpus (`nextomic_pull.zig`, checked against `entity()` and `datoms(.vaet)`), the shared fixture (`nextomic_fx.zig`), transaction functions and schema alteration (`nextomic_fn.zig`) and the lazy entity (`nextomic_entity.zig`) | `zig build test` (Nextomic ones also via `zig build nextomic-test`) |
| `examples/`, `test/examples/` | Every `examples/*.nx` runs through `bin/nexis` from a fresh directory, its stdout pinned to `test/examples/<name>.out`; an example with a `<name>.2.out` runs a second time over the store the first left | `zig build examples` (or `zig build test`) |

Every `.zig` file in `test/prop/` and `test/integration/` is a suite
of its own, found by the build; a `_fx.zig` file is a fixture the
suites import. `build.zig` names only the suites `zig build quick`
runs; the `nextomic_*` suites also run under `zig build nextomic-test`.

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
`nextomic-nx` steps); read the diff before committing it. Each run
reads its expected file when it runs: a mismatch fails that run with
the first differing line, and a missing file fails it and names the
flag.

A run is cached on the contents of everything it reads: the binary,
the script, its expected output, the files it loads (`prelude.nx`,
every file under `examples/lib/`, `test/golden/cli/lib/`) and its
environment. Every test binary and program runs with an environment
of its own, empty but for `NEXIS_GC_STRESS` (always set for
`test/nextomic/`, elsewhere under `-Dgc-stress`) and
`NEXIS_DURABILITY` (under `-Ddurability`); nothing exported in the
shell reaches it. A change to any of them re-runs it, a program in a
directory emptied that build. The two runs that share a store
(`persist-1`/`persist-2`, an example with a `.2.out`) both run on
every build.

## Running

`AGENTS.md` lists the build steps: `zig build quick` is the inner
loop (the `unit` binary, the compile and Nextomic property tests, the
`eval_pipeline`, `runtime_polish` and `numbers` suites) and
`zig build test --summary all` the gate, whose summary line
(`HANDOFF.md` §2) is the count of record; a run whose inputs are all
unchanged replays from the cache and counts no tests, so the count
comes from a run that ran (`--cache-dir` naming an empty directory).
Each property and integration file is its own binary, so they run in
parallel.

To run one binary by hand, `zig build quick --verbose` (or `test`)
prints each one's `zig test ... --listen=-` command; replace
`--listen=-` with `--test-no-exec -femit-bin=PATH`, then run PATH from
the build root, where the tests expect `.zig-cache/tmp/`.
