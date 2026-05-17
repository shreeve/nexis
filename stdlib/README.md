# stdlib

Reserved for the nexis standard library (the `core` namespace bootstrap).
Empty for now.

Per `PLAN.md` §21 Phase 3 and CLOJURE-REVIEW.md §1.1, this directory
will hold `core.nx` and friends — the Clojure-style two-stage bootstrap
where:

1. First, trivial renaming macros land: `(defmacro let [& decl] (cons 'let* decl))`.
2. Later, after destructuring helpers exist, `let` is redefined with the
   full destructuring-aware version.

The compiler primitives (`let*`, `fn*`, `letfn*`, `loop*`, `recur`,
`def`, `defn`, `if`, `do`, `quote`, `var`) are NOT in stdlib — they
live in the compiler (`src/compile.zig`). The user-facing `let`, `fn`,
`letfn`, `loop`, `defmacro`, `defn`'s docstring/destructuring shape,
`when`, `cond`, `case`, etc. are stdlib macros built on top of the
primitives.

This directory populates after step #8 (macroexpander) lands.
