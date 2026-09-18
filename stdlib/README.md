# stdlib

The nexis standard library sources live in `src/stdlib/` and are
embedded into the binary and bootstrapped at startup:

- `src/stdlib/core.nx`: the `nexis.core` composite layer (`let`, `fn`,
  `defn`, `when`, `cond`, `doseq`, threading macros, `with-tx`,
  `with-read-tx`, `with-snapshot`, and the collection helpers built on
  the compiler primitives and the native functions in `src/stdlib.zig`).
- `src/stdlib/nextomic.nx`: sugar for the Nextomic natives (`with-conn`).

Compiler primitives (`let*`, `fn*`, `letfn*`, `loop*`, `recur`, `def`,
`if`, `do`, `quote`, `var`, `set!`, `try`, `throw`) live in
`src/compile.zig`. Native functions live in `src/stdlib.zig` and
`src/nextomic/natives.zig`.
