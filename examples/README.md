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

These are the FIRST `.nx` programs to compile + run via the
CLI. More land as Phase 2/3 progress closes deferred items:

- Phase 2 step #8 (macroexpander): unlocks `when`, `cond`,
  `and`, `or`, `->`, `->>`, multi-arity `defn`, `#(...)` anon
  fn shorthand, syntax-quote, quoted compound collections.
- Phase 2 step #10 (error reporting): structured error
  messages with source spans.
- Phase 3 (stdlib): `map`, `reduce`, `filter`, `conj`,
  `assoc`, threading macros, protocols, multimethods, REPL,
  multi-namespace support.
