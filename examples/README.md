# examples

`.nx` programs that run through the `nexis` CLI.

```bash
zig build install                       # bin/nexis
./bin/nexis run examples/hello.nx
zig build examples                      # every example through bin/nexis
```

`zig build examples` (part of `zig build test`) runs every file below
from a generated working directory and compares what it prints with
`test/examples/<name>.out`; `durable-refs`, `todo-app` and
`nextomic-app` run a second time in the same directory, compared with
`test/examples/<name>.2.out`, which proves their second-run behavior.
`zig build examples -Dupdate=true` rewrites the expected files.

| File | What it shows |
|---|---|
| `hello.nx` | `defn` + call |
| `sum10.nx` | `loop`/`recur` constant-stack iteration |
| `forward-ref.nx` | `defn` forward references through the namespace Var (f calls g before g is defined) |
| `cond.nx` | `cond` + `and` + `:else` |
| `threading.nx` | `->` thread-first through `+` |
| `macros.nx` | `when-not` / `loop` / `or` host macros |
| `quoted-list.nx` | `(quote (...))` builds a runtime list |
| `syntax-quote.nx` | `` ` `` / `~` / `~@` with splicing |
| `macro-author.nx` | Synthesizing a `(let* [x 99] x)` form with a vector syntax-quote |
| `try-catch.nx` | `try` / `catch` / `throw` across frames; catch by keyword tag; `finally` alone |
| `metadata.nx` | `defn` docstrings and attribute maps, `(doc f)`, `^:private`, `with-meta` / `vary-meta` on collections |
| `binding.nx` | `^:dynamic` Vars and `binding`: nested extents, a function called inside one seeing the binding in force, restoration on throw, `set!` on the innermost binding, `:not-dynamic` |
| `maps-sets.nx` | `{...}` and `#{...}` literals |
| `defmacro.nx` | User macros: a fresh sub-VM per compile-time invocation |
| `eval.nx` | `eval` with `read-string`: a form as data compiled and run on the calling VM; a `def` and a `defmacro` inside it visible afterwards, a returned closure, the catchable `:compile-error` map, a throw from inside the form |
| `stdlib-primitives.nx` | Native fns (`list`/`cons`/`first`/`rest`/`empty?`/...) and a recursive procedural `my-cond` macro |
| `require-demo.nx` + `lib/geom.nx` | `(require '[lib.geom :as g])` loads a library from disk |
| `shapes.nx` | Protocols + records in one file: `defprotocol`, `defrecord`, `extend-protocol` over records and built-ins, `satisfies?`, atoms, `str`, `case`/`for` |
| `typed-vectors.nx` | `i64-vector` / `f64-vector`, the generic functions over them, the `nexis.simd` kernels (`tv/sum`, `tv/dot`, `tv/scale`, `tv/map`), equality rules and the `:kind-mismatch` / `:index-out-of-bounds` errors |
| `tests-demo.nx` | `nexis.test`: `deftest`, `is` (`=`, `thrown?`, bare), `testing`, `run-tests`; one test fails, one throws, so the report shows every outcome and the summary map |
| `shapes-app.nx` + `lib/shapes/{protocol,records,builtins}.nx` | The same program as a multi-file application: a driver and three required modules; prints one report per shape and `total-area atom = 9650` |
| `durable-refs.nx` | Durable identity backed by emdb: `db/open`/`db/ref`/`db/put-key!`/`db/get-key`/`db/delete-key!`; values persist across processes |
| `todo-app.nx` | Persistent to-do tracker over the whole `db/*` surface (`with-tx`, `db/alter!`, `db/scan`, `db/reduce-tree`, `@deref`, rollback on exception). Run twice: the second run shows `:completed 1` |
| `nextomic-app.nx` | A clinic chart on Nextomic (`docs/NEXTOMIC.md`): schema as data, upserts by unique identity, component notes, Datalog queries with `d/q` (joins, `:in`, a predicate, an aggregate), `d/pull` patterns (nested, reverse, component), `as-of`/`history`/`tx-range` reads, a speculative `d/with`, a caught `:nextomic/unique`. Safe to run twice: the second run re-upserts the same patients and advances only the basis |

The store-backed examples write under `tmp/` relative to the working
directory; delete it to start from an empty store.

The macro examples cover both styles: host macros (Zig-implemented,
registered in the default table) and user macros (`defmacro`,
compile-time VM eval). Lexical bindings shadow both; user macros
shadow host macros.
