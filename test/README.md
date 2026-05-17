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
| `test/fuzz/` | Reserved for Phase 6+ fuzz testing. Empty for now. | — |
| `test/integration/` | Reserved for Phase 6+ end-to-end source-to-execution tests. Empty for now. | — |

## Two build steps for two loops

- **`zig build phase2-test`** (~3 seconds) — runs ONLY the `vm` + `compile`
  module tests. The inner edit/test loop for Phase 2 compiler/VM work.
- **`zig build test`** (~3 minutes) — runs the full Phase 0/1/2 suite,
  property tests, and golden verification. ~3 min runtime is dominated
  by Phase 1's randomized HAMT correctness gate. Run before commits.

## Counts at last update (commit `4373b6e`)

- `vm`: 86 inline tests
- `compile`: 135 inline tests
- Phase 0/1 modules + property tests: ~454 tests
- Reader golden: 10
- Total: ~685 tests

## Removed directories

`test/unit/` and `test/bench/` previously existed as empty placeholders.
Both were removed for clarity:

- `test/unit/` contradicted the inline-test convention (new contributors
  would look there for unit tests and find them missing).
- `test/bench/` was empty; benchmark code lives in `bench/` (project
  root) and benchmark data in `bench/baseline*.json`.
