# stdlib

The nexis standard library sources live in `src/stdlib/` and are
embedded into the binary and bootstrapped at startup by `stdlib.boot`
(`src/stdlib.zig`), in this order, each with its namespace current:

- `src/stdlib/core.nx`: the `nexis.core` composite layer written in
  nexis: the threading and conditional macros (`if-let`, `when-some`,
  `doseq`, `dotimes`, `doto`, `time`, `with-out-str`, ...), `binding`,
  `with-tx`/`with-read-tx`/`with-snapshot`, and the collection and
  function helpers built on the native functions in `src/stdlib.zig`
  (`docs/MACROEXPAND.md` §2b lists the macros).
- `src/stdlib/nextomic.nx`: sugar for the Nextomic natives (`with-conn`).
- `src/stdlib/test.nx`: `nexis.test` (`deftest`, `is`, `testing`,
  `run-tests`).
- `src/stdlib/pprint.nx`: `nexis.pprint`.
- `src/stdlib/math.nx`: the constants of `nexis.math`.
- `src/stdlib/string.nx`: the `nexis.string` functions written over its
  natives (`capitalize`, `reverse`, `split-lines`).
- `src/stdlib/set.nx`: `nexis.set`, Clojure's `clojure.set`.

Each file may use the natives and the files before it. A definition
that needs bytes, bits, the clock or a callback loop that must stop
early is a native; the rest is nexis.

The files build the keywords they need at run time (`(keyword "doc")`)
rather than writing keyword literals. The reason is output order, and
only that: a keyword's hash follows the order keywords are interned,
so a literal read at boot shifts the iteration order of every map a
program prints, and with it the pinned outputs under `test/nextomic/`
and `test/examples/`. Once keyword hashing no longer follows intern
order the files may use literals freely.

The host macros (`let`, `fn`, `defn`, `when`, `cond`, `case`, `for`,
`try`, ...) live in `src/expand.zig` (`docs/MACROEXPAND.md` §2). Compiler
primitives (`let*`, `fn*`, `letfn*`, `loop*`, `recur`, `def`, `if`,
`do`, `quote`, `var`, `throw`) live in `src/compile.zig`. Native
functions live in `src/stdlib.zig` and `src/nextomic/natives.zig`.
