# examples

Tiny `.nx` programs that run via the `nexis` CLI (step H1).

```bash
# Build the CLI (produces bin/nexis):
zig build nexis

# Run an example:
./bin/nexis run examples/hello.nx
```

| File | What it shows |
|---|---|
| `hello.nx` | Symbol literal via `defn` + call |
| `sum10.nx` | `loop*`/`recur` constant-stack iteration |
| `forward-ref.nx` | `defn` forward references work via the namespace Var fall-through (f calls g before g is defined) |
| `cond.nx` | `cond` + `and` + `:else`-as-truthy-keyword convention |
| `threading.nx` | `->` thread-first chained through `+` |
| `macros.nx` | `when-not` / `loop` / `or` end-to-end (step #8b host macros) |
| `quoted-list.nx` | `(quote (...))` builds a runtime list value via `#%list` (step #8c.1) |
| `syntax-quote.nx` | `` ` `` / `~` / `~@` with splicing (step #8c.2) |
| `macro-author.nx` | Synthesize a `(let* [x 99] x)` form via vector syntax-quote (step #8c.3) |
| `try-catch.nx` | `try` / `catch` / `throw` with cross-frame propagation (step #9.1) |
| `maps-sets.nx` | Collection literals `{...}` and `#{...}` (Phase 3.1) |
| `defmacro.nx` | User-defined macros via `defmacro` (Phase 3.2) — fresh sub-VM per compile-time invocation |
| `stdlib-primitives.nx` | Native fns (`list`/`cons`/`first`/`rest`/`empty?`/...) + a user-written recursive procedural `my-cond` macro (Phase 3.3a) |
| `require-demo.nx` + `lib/geom.nx` | `(require '[lib.geom :as g])` loads a library from disk; Phase 3.6 |
| `durable-refs.nx` | First-class durable identity backed by emdb. `db/open`/`db/ref`/`db/put-key!`/`db/get-key`/`db/delete-key!`. Phase 4.0a — values PERSIST across processes. |

The macro-heavy examples cover both styles: host macros (Zig-
implemented, registered in the default table) and user macros
(`defmacro` — compile-time VM eval). Lexical bindings shadow
both; user macros shadow host macros.

Future (Phase 3.3+):
- Host fns for macro authoring (`cons`/`first`/`rest`/`list`/
  `count`/`nth`/`apply`/`seq`) — unlock procedural macros.
- `stdlib/core.nx`: `map`/`reduce`/`filter`/`conj`/`assoc` +
  destructuring `let`/`fn` + multi-arity `defn`.
- Multi-namespace: `(require ...)`/`(use ...)`/qualified
  symbols.
