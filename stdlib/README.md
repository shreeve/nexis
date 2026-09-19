# stdlib

The nexis standard library sources live in `src/stdlib/` and are
embedded into the binary and bootstrapped at startup:

- `src/stdlib/core.nx`: the `nexis.core` composite layer written in
  nexis: the threading macros, `when-let`/`if-let`/`doseq`/`dotimes`,
  `binding`, `with-tx`/`with-read-tx`/`with-snapshot`, and the
  collection helpers built on the native functions in `src/stdlib.zig`
  (`docs/MACROEXPAND.md` §2b lists the macros).
- `src/stdlib/nextomic.nx`: sugar for the Nextomic natives (`with-conn`).
- `src/stdlib/test.nx`: `nexis.test` (`deftest`, `is`, `testing`,
  `run-tests`).
- `src/stdlib/pprint.nx`: `nexis.pprint`.
- `src/stdlib/math.nx`: `nexis.math`.

None of them may contain a keyword literal: they bootstrap before the
reader's keyword table is in place (`docs/TOOLING.md` §3).

The host macros (`let`, `fn`, `defn`, `when`, `cond`, `case`, `for`,
`try`, ...) live in `src/expand.zig` (`docs/MACROEXPAND.md` §2). Compiler
primitives (`let*`, `fn*`, `letfn*`, `loop*`, `recur`, `def`, `if`,
`do`, `quote`, `var`, `throw`) live in `src/compile.zig`. Native
functions live in `src/stdlib.zig` and `src/nextomic/natives.zig`.
