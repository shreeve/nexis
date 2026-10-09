# examples

Small nexis programs, each a lesson in the language. nexis is Clojure
on its own runtime, so most of what they show reads as Clojure does;
where nexis differs, the comments say so.

```bash
zig build install                       # builds bin/nexis
./bin/nexis run examples/hello.nx       # run one
./bin/nexis repl                        # try a line at a time
```

Each file starts with a comment saying what it shows. Read them in
this order:

| File | What it teaches |
|---|---|
| `hello.nx` | A function, a string, `println` and `*command-line-args*` |
| `basics.nx` | `let`, `fn` and `#(...)`, multi-arity `defn`, destructuring of vectors and maps, `if`/`when`/`cond`/`case`, `if-let`/`when-let`, `loop`/`recur`, `->` and `->>`, a closure |
| `collections.nx` | Vectors, maps and sets as values: `assoc`/`update`/`assoc-in`/`update-in`, `merge-with`, `into`, `group-by`, `frequencies`, `sort-by`, `reduce`, `for`, ending in a report built from nested data |
| `sequences.nx` | Lazy sequences: `map`/`filter`/`take`, infinite `range`/`iterate`/`cycle`, `partition`, a `lazy-seq` Fibonacci, `reductions`, transducers with `into` and `transduce` |
| `strings.nx` | `str`, `format`, `subs`, counting characters not bytes, and `clojure.string`: `join`, `split`, `trim`, `replace`, with `re-find` and `re-seq` |
| `word-freq.nx` | A small program: the most frequent words of a paragraph, as one `->>` pipeline |
| `errors.nx` | `throw` of any value, `ex-info`/`ex-message`/`ex-data`, `catch` by tag or class name, `finally`, rethrowing with a cause |
| `shapes.nx` | Protocols and records: `defprotocol`, `defrecord`, `extend-protocol` over strings, numbers and `nil`, `satisfies?`, a record as a map |
| `shapes-app.nx` | The same as a program in several namespaces under `lib/shapes/`, loaded with `ns` and `:require` |
| `require-demo.nx` | `require` of a library file (`lib/geom.nx`), with `:as`, `:refer` and `:rename` |
| `macros.nx` | `defmacro`, syntax-quote, `~` and `~@`, auto-gensyms, `macroexpand-1`; an `unless`, a `with-retries` and a `when-valid` |
| `multimethods.nx` | `defmulti`/`defmethod` dispatching on a key, on a type and on a vector, `derive` hierarchies, `prefer-method` |
| `binding.nx` | `^:dynamic` Vars and `binding` |
| `metadata.nx` | Docstrings and attribute maps on `defn`, `(doc f)`, `with-meta` and `vary-meta` |
| `eval.nx` | Code as data: `read-string` and `eval` |
| `regex.nx` | `#"..."` patterns in depth: groups, named groups, matchers, flags, replacement functions |
| `typed-vectors.nx` | `i64-vector` and `f64-vector`, and the `nexis.simd` kernels over them |
| `tests-demo.nx` | Unit tests with `nexis.test` (`clojure.test`): `deftest`, `is`, `testing`, `run-tests` |
| `durable-refs.nx` | Durable refs: values in a store file that outlive the process; `with-tx` and rollback |
| `todo-app.nx` | A to-do list kept in a store: `db/alter!`, `db/scan`, `db/reduce-tree` |
| `nextomic-app.nx` | A clinic chart on Nextomic, the built-in database: schema as data, Datalog `q`, `pull`, `as-of` and `history`, a speculative `with` |

The last three keep their data in `tmp/` under the working directory
and are meant to be run twice: `durable-refs` counts its runs,
`todo-app` starts its second run from the state the first left, and
`nextomic-app` shows in its history the facts both runs added. Delete
`tmp/` to start over.

`zig build examples`, part of the gate, runs every program here from
a fresh directory and compares its output with
`test/examples/<name>.out` (and the second run of the store-backed
ones with `<name>.2.out`); `-Dupdate=true` rewrites those files.

`test/examples/pins/` holds programs that pin low-level behaviour of
the compiler and runtime rather than teach; they run in the same step.
For the language as a whole, `docs/GUIDE.md` is nexis for Clojure
programmers, and the REPL describes itself: `(doc name)`,
`(dir nexis.string)` and `(apropos "split")`.
