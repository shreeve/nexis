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

The macro-heavy examples (`cond.nx`, `threading.nx`,
`macros.nx`) all rely on step #8b host macros. Step #8c
will unlock `syntax-quote`, quoted compound collections,
and `#(...)` anonymous-fn shorthand.

Future:
- Phase 2 step #8c: syntax-quote, `~` / `~@`, `#(...)` anon fn.
- Phase 2 step #10 (error reporting): structured error
  messages with source spans.
- Phase 3 (stdlib): `map`, `reduce`, `filter`, `conj`,
  `assoc`, protocols, multimethods, REPL, multi-namespace
  support.
