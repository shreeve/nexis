# MACROEXPAND.md — the macroexpander

The contract for `src/expand.zig` and the `require` side of
`src/loader.zig`: expansion semantics, host macros and user
`defmacro`, the run-time expander (`macroexpand`, `eval`),
syntax-quote and auto-gensym, each special form's traversal rule,
`ns` and `require`, and the error model. It rests on PLAN §23 #16,
#29, #31 and #34; [`COMPILER.md`](COMPILER.md) consumes its output.

---

## 0. Where the macroexpander sits

A Form → Form rewriter between the reader and lowering:

```
source → parser.parseProgram → Sexp → Reader.readProgram → []*Form
       → expandForm (this doc) → expanded Form → lowerForm → Tiny
       → emitter → Routine → VM
```

`compileFormWith` runs it on each top-level form whenever it has an
interner. It walks the form by each special form's rule (§2b),
expands every macro call until its head is no macro, and rewrites
away `syntax_quote`, `unquote`, `unquote_splicing`, `anon_fn`, `@x`
and `^meta`, so lowering sees only atoms, lists, vectors, maps, sets
and `quote`. It adds no Form datums, no Tiny nodes and no opcodes:
its output is ordinary forms, and `#%list` / `#%concat` / `#%vector`
/ `#%map` / `#%set` lower to the `coll:*` opcodes quoted literals
use.

---

## 1. Execution model

Macros come in two kinds, found by one lookup (§1.1):

- **Host macros**: Zig functions in a `HostMacroTable`
  (`std.StringHashMapUnmanaged(MacroFn)`), installed by
  `defaultMacros` (§10). A `MacroFn` takes the context, the call
  form and the argument forms, and returns the rewritten form,
  which is expanded again.
- **User macros**: Vars with `macro = true`, defined by `defmacro`
  and run at expansion time in a sub-VM (§1.2).

The compiler builds one `ExpandContext` per top-level form. Its
fields:

| Field | Role |
|---|---|
| `allocator` | the compile arena: every Form the expander builds, failure messages |
| `interner` | symbols and keywords of macro arguments and syntax-quote |
| `host_macros` | the host macro table; empty disables host expansion |
| `namespace` | where user macros are looked up and syntax-quote qualifies; null: no user macros |
| `compile_eval` | the callback `defmacro` compiles and runs its function through; null: `defmacro` fails |
| `registry` | what `ns` switches and `require` refers into; null: both fail |
| `load_callback` | the loader `require` calls (§2b); null: `require` fails |
| `value_heap` | the calling VM's heap, where macro arguments and results live; else a lazily created heap on `allocator` |
| `io` | given to a user macro's sub-VM so its body can print |
| `source` | the text the forms were read from, which places `&form` (§1.3); null for `eval`'s and `macroexpand`'s forms |
| `failure` | the span and message of the innermost failure (§8) |
| `lexical` | the lexical names in scope where the walk is (§3) |

`ctx.gensym(base)` makes `<base>__<N>__auto__` (§4).

### 1.1 Lookup order in `expandList`

For a list whose head is an unqualified symbol:

1. **Special forms** (§2b) come first, are never macros and cannot
   be shadowed: the keys of `expand.special_forms` (`quote`, `var`,
   `if`, `do`, `recur`, `throw`, `let*`, `loop*`, `fn*`, `letfn*`,
   `def`, `set!`, `try`, `defmacro`, `ns`, `require`), each with its
   own walker, and every `#%` name (`#%list`, `#%concat`, ...),
   whose arguments expand as a call's do.
2. A name a binding form around the call binds is an ordinary call (§3).
3. **User macro**: `namespace.lookup(name)` yields a bound Var with
   `macro = true` → §1.2. Any other Var it yields that is not
   `nexis.core`'s (one the namespace defines or excludes, or a
   referred one) makes the list an ordinary call: `(defn when [x]
   ...)` then `(when 1)` calls the function, as in Clojure.
4. **Host macro**: `host_macros.get(name)` → call it, then expand
   its result.
5. Otherwise an ordinary call: expand the head and every argument.

A qualified head `alias/name` or `ns/name` names a user macro when
the alias or namespace is registered and its own Var `name` is a
bound macro, or a host macro when it resolves to `nexis.core`;
otherwise it is an ordinary call. User macros shadow host macros.

### 1.2 User-defined `defmacro`

1. **`Var.macro`** is a field on every Var (`src/vm.zig`).
2. **`defmacro` is an expander special form** spelled exactly like
   `defn`: a docstring, an attribute map and `^meta` on the name
   become the Var's metadata, with `:macro true` as Clojure's has it,
   parameters destructure and overload
   clauses dispatch on argument count, as for `fn`, and puts `&form`
   and `&env` in front of each arity's parameters (§1.3). The expander
   builds `(def name (fn name ...))` (wrapped to set the metadata as
   `defn` does), expands it in the enclosing env, compiles and runs
   it through `ctx.compile_eval` in a fresh sub-VM, and sets the
   Var's `macro` flag. The form is replaced by `(var name)`, so the
   REPL prints `#'ns/name`.
3. **Invocation**: the argument count, with `&form` and `&env`, is
   checked against the macro function's arities, each argument Form
   becomes a Value
   (`formToValue`), and a fresh sub-VM (an idle routine, the
   compile-time interner, the calling VM's heap, collection off,
   `ctx.io`) calls the macro function through `callValue`. The
   sub-VM uses the registries of the VM that owns `ctx.namespace`'s
   registry (`docs/VM.md` §9.1): `resolve`, `all-ns`, `in-ns`,
   `reduced`, `delay`, record constructors, protocol fns and `db/open`
   in a macro body see and change the program's namespaces, record
   types, protocols and stores. Its
   result, every lazy seq in it realized on the sub-VM and made a list
   (`seq.asLists`, `docs/LAZY.md` §8), becomes a Form (`valueToForm`)
   placed as §4b says, or its
   throw or VM error becomes the failure message (§8). The sub-VM is
   released and the result is expanded again in the call's place.
4. **A fresh sub-VM per call**: no handler, finally or halted state
   to save and restore. The macro routine's Var table points into
   the caller's namespace and its constants are caller-interned, so
   the sub-VM needs no namespace of its own.
5. **Persistent storage**: `compile_eval` compiles the definition on
   the enclosing form's compile allocator with its routines on
   `CompileOptions.persistent_allocator` (the VM's runtime arena for
   the CLI and the REPL), so the macro outlives the form while its
   trees do not, and runs it on a sub-VM over the calling VM's heap
   and registries, released once it has run; the closure is on that
   heap, rooted by the Var. The definition compiles with the
   enclosing form's declared names: a name in the body that resolves
   to nothing is reported at the `defmacro` (`defmacro m: unable to
   resolve symbol: x`, at `x`), as Clojure reports it.
6. **Form ↔ Value.** Form → Value (`formToValue`): nil, booleans,
   integers (a fixnum, or a bignum past the fixnum range or for a
   `bigint`), reals, chars, strings, symbols and keywords (interned,
   qualified by their full name), lists, vectors, maps and sets;
   `'x` as `(quote x)`, `@x` as `(nexis.core/deref x)`, `#()` as the
   `fn*` form it stands for, `^m coll` as the list, vector, map or
   set carrying `m` (on anything else, a symbol included, the
   metadata is dropped), and the marker list a sorted collection
   travels as (below) as the collection. Only a syntax-quote, unquote
   or unquote-splicing is refused, as `MalformedMacroCall` at the
   argument. `quote` makes its constant (`COMPILER.md` §5.1) and
   `read-string` its value the same way. Value → Form
   (`valueToForm`): nil, booleans, fixnums, bignums (an `int` within
   i64, else a `bigint`), floats, chars, strings, symbols, keywords,
   lists (including a vector's seq view), vectors, maps and sets, after
   every lazy seq in the value is realized and made a list (a macro's
   result, `eval`'s and `macroexpand`'s argument); the
   list `(nexis.internal/#%meta x m)` becomes `^m x` (§5). A sorted map
   or set in the natural order becomes the list
   `(nexis.internal/#%sorted-map k v ...)` or `(nexis.internal/#%sorted-set x ...)`,
   which evaluates to the collection and which `quote` folds to the
   collection itself; one with a comparator of its own holds code, and
   is `MalformedMacroCall`. Any other kind (a function, a Var, an atom)
   is `MalformedMacroCall`. A list's `:line` and `:column` metadata
   does not become `^meta`: a form's place is its span, so a list
   returned with `(with-meta out (meta &form))` is `out`, at the call's
   span, and a list with other metadata keeps the rest.
7. **Variadic macros** (`& body`) work; `recur` in a variadic macro
   body is rejected as at run time.
8. Macro arguments are **unevaluated forms as data**: a macro body
   inspects them with the core natives (`first`, `rest`, `cons`,
   `list`, `count`, `nth`, `seq?`, ...) and builds its output with
   syntax-quote or those natives.
9. **The expander at run time.** The natives reach the compiler
   through `vm.CompilerHooks` (`compile.RuntimeHooks`, installed by
   the runtime that boots the VM) and build their values on the VM
   heap; a VM without hooks throws `:no-compiler`. A macro's sub-VM
   has `macroexpand-1`, `macroexpand` and `read-string` but not
   `eval` or `load-string`, which throw `:no-compiler` there
   (`docs/VM.md` §9.1).
   - `(macroexpand-1 form)` is one macro step (`expandOnce`: a user
     or host macro at the head, never a special form or `#%`
     primitive; the raw output, nothing inside it expanded, `&env`
     nil, §1.3), or the form itself. `^meta` on the form is
     dropped first, as on any call (§2b). `macroexpand` repeats
     it until the head is not a macro. A failure throws the error map
     of `:macro-expansion-failure` (`docs/VM.md` §13), its `:message`
     the expander's sentence (§8): what the macro threw, or why the
     form is malformed.
   - `(read-string s)` reads the first form of `s` as data; a reader
     error throws `:reader-error`. Only the text up to the end of the
     first form is scanned and read (`reader.firstFormEnd`), so what
     follows it is ignored, as in Clojure, even text that would not
     read. A text with no first form is read whole, to tell one that
     holds no form (the hook answers null, and `read-string` gives
     its `:eof` option, `docs/STDLIB.md` §2) from one that ends inside
     a form.
   - `(eval form)` converts the value to a Form, then compiles it as
     the REPL compiles a line: the current namespace, the registry,
     interner, host macros and loader, a fresh set of declared
     names. It runs the routine on the calling VM as a nested call
     (`vm.runRoutine`) and returns its value; a `do` runs its forms
     one at a time, as a loaded file's top-level `do` does (§2b). A `def` inside binds
     in the current namespace, a `defmacro` serves a later `eval`,
     `(ns ...)` switches the current namespace, a returned closure
     stays callable, a dynamic binding in force is seen, and `eval`
     nests. The form has no lexical environment: a caller's
     `let`-bound name is `UnresolvedSymbol` inside it. The Form and
     Tiny trees live in a scratch arena freed when `eval` returns;
     the routine, its constants and every closure prototype live in
     the VM's runtime arena. A value that is not a form (a list
     holding a function) and a form that does not compile throw
     `{:error :compile-error :message m :form form :kind name}`, `m`
     the compiler's sentence (`"unable to resolve symbol: nope"`, the
     expander's reason) or, with none, the `CompileError` name in
     words (`"unsupported form"` for a non-form), and `name` that
     name (`"UnsupportedForm"`), with the place of the `eval` call
     when a handler is in force (`docs/VM.md` §13); so
     `(catch :compile-error e ...)` takes it and `ex-message` reads
     the sentence. A throw inside the evaluated form propagates as an
     ordinary throw.
   - Syntax-quote is not data at run time: a quoted form holding one
     is `UnsupportedFeature` at compile and `read-string` rejects
     it, so a form built for `eval` uses `list`, `cons` and quote.

### 1.3 `&form` and `&env`

A user macro's function takes two parameters before the ones its
`defmacro` names: `&form`, the call, and `&env`, the locals in scope
at it, as Clojure's does.

- **`defmacro`** puts the plain symbols `&form` and `&env` at the
  front of every arity's parameter vector, after the `:arglists` are
  taken, so `(:arglists (meta #'m))` and `(doc m)` show the
  parameters as written. They are ordinary locals of the macro's
  function: a body or a nested binding may shadow them, a `recur` to
  the top of the function passes them, and `(#'m form env args...)`
  calls the function directly.
- **At a call** (`callUserMacro`) the argument count is checked
  against the function's arities with the two added, and an arity
  error counts the arguments alone ("macro m takes 1 argument, got
  0"). The function is called with `&form`, `&env` and the
  arguments.
- **`&form`** is the list of the head symbol, as written (`m`,
  `a/m`, `my.ns/m`), and the argument values themselves:
  `(identical? (second &form) x)` holds for the first parameter `x`.
  When the form being expanded came from a source text
  (`ExpandContext.source`), the list carries the metadata
  `{:line l :column c}`, the 1-based line and column, in code points,
  of the call's first character, which is where an error report puts
  the call. A call a macro built carries the span of the macro call
  that built it (§4b), so its place is that call's. A form `eval`,
  `load-string` or `macroexpand-1` is given has no source, and its
  `&form` carries no metadata. `^meta` written on a call is a hint and
  is dropped (§2b) before the macro runs. The lists inside the
  arguments carry their own `^meta` (item 6 of §1.2) and no place.
- **`&env`** is nil when no local is in scope at the call: at the top
  level, in a body whose binding forms bound nothing. Otherwise it is
  a map from the name of every local in scope to that name, a
  symbol: the names `ExpandContext.lexical` counts (§3), which every
  `let*`, `loop*`, `fn*` (its parameters and its own name),
  `letfn*` and `catch` around the call binds, and so the binding
  forms the host macros expand to, destructuring gensyms included.
  A name bound in a `let`'s later binding is not yet in scope in an
  earlier one's value. The values are truthy, so `(&env 'x)`,
  `(get &env 'x)` and `(contains? &env 'x)` each tell whether `x` is
  a local here, and `(keys &env)` lists them. A `.cljc` macro that
  tests `(:ns &env)` for ClojureScript takes its Clojure branch.
- **At run time**, `macroexpand-1` and `macroexpand` (§1.2 item 9)
  pass the form as data as `&form` and nil as `&env`, also when
  called from inside a macro's body.
- **Host macros** take neither: a `MacroFn` has the call form and
  `ctx.lexical` already.

Where nexis and Clojure differ, deliberately (`CLOJURE-REVIEW.md`):

- `&env`'s values are the locals' symbols, not Clojure's
  `LocalBinding`s, which only Java interop reads. A symbol costs no
  allocation, is truthy, and is what babashka gives.
- `&env` comes from the expander's `lexical`, not the compiler's
  locals: nexis expands a whole top-level form before lowering it, and
  `lexical` tracks the binding forms the compiler lowers, so "is a
  local" means one thing here and in §3.
- Only `&form` carries a place. Clojure's reader puts `{:line
  :column}` on every list it reads from a file; here that would cost
  a map per list of every argument, and errors are placed by span
  (§4b). There is no `:file` key, as in Clojure's reader.
- `^meta` on the call is not merged into `&form`: it is a dropped
  hint (§2b).
- `macroexpand-1` called from a macro body passes a nil `&env`, where
  Clojure passes the compile environment it is running in.

**Cost.** Per user-macro call: the `&form` list of n+1 cells over
values already built, and with a source a 2-entry map and a place
lookup; `&env` nothing with no local in scope, else one pass over
`lexical`, a symbol intern lookup per local and one map build. The
place is found from the last place the owning VM found
(`VM.placeOf`, `SourceInfo.lineColFrom`, `docs/VM.md` §13), so the
expansions of a file scan its text about once in all, not once per
call from its start. The `&form` list and the `&env` map live on the
calling VM's heap with the arguments, while a sub-VM that never
collects runs the macro, so they need no rooting.

---

## 2. Example: `(when test body)`

`(when (< x 10) (def y x) y)` reads as a list headed by the symbol
`when`. The head is no special form, not lexically bound and no user
macro, so `host_macros` supplies `expandWhen`, which returns

```
(if (< x 10) (do (def y x) y) nil)
```

built with the call's span (§4b); the test and body forms are the
input's own Forms, shared, not copied. The result is expanded again:
`if` and `do` are special forms whose sub-forms are walked (§2b),
`(< x 10)` and `(def y x)` contain no macros, and the walk ends.
Lowering sees an ordinary `if` (`COMPILER.md` §5.2).

---

## 2b. Special-form traversal rules

Each special form has its own walk; the expander never recurses
blindly, which would expand names that are not expressions (the
name in `(def x ...)`) or miss bodies that are.

| Form | Traversal rule |
|---|---|
| `quote` | Opaque: the payload is not walked (§7). |
| `syntax_quote` (datum) | Rewritten per §5. |
| `anon_fn` (datum) | Rewritten to `fn*` per §9. |
| `let*`, `loop*` | Binding names are not expanded. Each right-hand side expands with the bindings before it in scope; the body with all of them. |
| `fn*` | `(fn* name? [params] body*)` or `(fn* name? ([params] body*)+)`, a clause per arity (`COMPILER.md` §5.5). The parameter vectors and self-name are not expanded; each body expands with its clause's params, rest param and the self-name in scope. A clause that is not a list starting with a parameter vector is `MalformedMacroCall`. |
| `letfn*` | Names and parameter vectors are not expanded. Every name enters scope first; each entry, `(name [params] body*)` or `(name ([params] body*)+)`, goes through `fn`'s lowering, so its params destructure and its overload clauses become `fn*`'s, and each function body expands with the names and its params in scope; then the body. |
| `def` | The name is not expanded and does not enter scope (Vars are not lexical); the value expands. |
| `var` | Opaque. |
| `if`, `do`, `recur`, `throw`, `#%` constructors, ordinary calls | Every sub-form expands in the current env. |
| `set!` | `(set! target v)` → `(nexis.core/var-set (var target) v)` with `v` expanded. `target` must be a symbol; a lexical name is refused (a local has no thread binding). The Var's own checks (`:not-dynamic`, `:no-thread-binding`) happen at run time (`VM.md` §6.5). |
| `try` | `(try body* (catch M b h*)* (finally f*)?)` becomes the primitive `(try body* (catch any g <chain>) (finally f*)?)`. The chain tries the clauses in order, `(if (nexis.internal/#%catch-matches? g M) (let* [b g] h*) ...)`, and ends in `(throw g)`, so a value no clause takes unwinds through the `finally`. A matcher is `any`; a class name that names a nexis error, which takes that error's tags (`ArithmeticException` `:divide-by-zero` and `:arithmetic-overflow`; `IndexOutOfBoundsException`, `ArrayIndexOutOfBoundsException` and `StringIndexOutOfBoundsException` `:index-out-of-bounds`; `ClassCastException` `:kind-mismatch` and `:not-callable`; `IllegalArgumentException` `:invalid-argument`, `:no-matching-clause`, `:arity-mismatch`, `:no-method` and `:ambiguous-method`; `IllegalStateException` `:preference-conflict`; `ArityException` `:arity-mismatch`; `AssertionError` `:assertion-failed`; `StackOverflowError` `:stack-overflow`; bare or under `java.lang.`, `java.util.` or `clojure.lang.`); any other symbol (a class name such as `Exception`, taken as `any` since nexis has no classes); `:default` (also `any`); or a keyword `:tag`, which takes a thrown value equal to `:tag`, a map or record whose `:error` is `:tag`, or an `ex-info` map whose data's `:error` is `:tag`; a runtime error arrives as its error map (`VM.md` §13), so `:kind-mismatch`, `ClassCastException` and `any` all take `(+ 1 "a")`'s. Any other matcher, a catch or finally before the body's end, or a binding that is not an unqualified symbol is `MalformedMacroCall`. No clause: a finally-only `try`; neither clause: `(do body*)`. The body, each handler (its binding in scope) and the finally body expand; matchers and bindings do not. |
| `defmacro` | §1.2; replaced by `(var name)`. |
| `ns` | `(ns NAME "doc"? {attrs}? clause*)` switches `registry.current` to `NAME` at expansion time, creating it (parent `nexis.core`) when unregistered, then runs each `(:require spec*)` clause as `require` does. `(:refer-clojure :exclude [names])` interns each name `nexis.core` or the host macro table holds as an unbound Var of the namespace, so the name resolves, inlines and expands as the namespace's own from then on (a use before the namespace defines it is `:unbound-var` at run time; `nexis.core/name` still reaches core's), until the namespace defines it or a `:refer` of another namespace's Var of the name replaces it, as Clojure, which maps an excluded name to nothing, lets one; `(:refer-clojure)` alone does nothing, and `:only` or `:rename` is `MalformedMacroCall`. `(:gen-class)` is accepted and does nothing; the docstring and attribute map are accepted and not kept; any other clause (`:import`, `:use`) is `MalformedMacroCall`. Every clause, its options and its specs, is checked before the switch, so a malformed one leaves the namespace as it was; a namespace that does not load fails after it, as Clojure's `ns` fails after its `in-ns`. Replaced by `nil`. |
| `require` | `(require spec*)`: each spec, quoted or not, is `ns-name` or `[ns-name option*]`, loaded at expansion time through `load_callback` and replaced by `nil`. `:as a` aliases the namespace; `:as-alias a` aliases it without loading; `:refer [x y]` maps `x` and `y` in the current namespace to that namespace's Vars (the same Vars: a later `def` there is seen here); `:refer :all` maps every Var not marked `:private`; `:rename {x z}` names a referred `x` as `z`. A prefix list, a vector whose second element is not a keyword or any list, requires each suffix under its prefix, as Clojure's does: `[app c [d :as dd]]` and `(app c [d :as dd])` are the specs `app.c` and `[app.d :as dd]`; a suffix holding a period, a suffix that is itself a prefix list, and a suffix other than a symbol or vector are `MalformedMacroCall`. A keyword spec (`:reload`) is a flag and changes nothing. Referring a name the current namespace defines itself, and `def` of a name that refers to another namespace's Var, are `MalformedMacroCall` (Clojure's rule); a missing Var or unknown option is reported by name. |
| Non-symbol head | An ordinary call: head and arguments expand. |
| `^meta` | On a vector, map or set literal: `(nexis.core/with-meta coll {meta})`, the map evaluated like any map literal except that a symbol under `:tag` and the vector under `:param-tags` are quoted, so `(meta ^:foo [1])` is `{:foo true}`. On anything else in expression position (a symbol, a call) it is a hint and is dropped. In every binding position (`let`, `loop`, `let*`, `loop*`, `fn` and `fn*` names and patterns, a parameter vector as a return hint, `:keys` entries, `defrecord` fields, a `catch` binding) it is dropped: `(defn f ^long [^String s] ...)` is `(defn f [s] ...)`. On the name of `def`, `defn` or `defmacro` it becomes the Var's metadata, `^String` as `{:tag String}` with the tag quoted. |

Every sub-form is expanded exactly once, so a user macro runs once
per call site.

**The loader** (`src/loader.zig`). `require` reaches it through
`load_callback`. `Loader.evalSource` is the one path from text to
effect for `run`, `repl`, `disasm`, the stdlib bootstrap and
`require`: parse, read, declare the names the text defines, compile
and run each top-level form. A top-level form's head is expanded
first until it names no macro (`compile.expandTopLevel`); a `do` it
comes to runs its forms one at a time, each taken the same way, as
Clojure's `eval` runs them, so an `ns`, `def` or `defmacro` among
them is in force for the forms after it: `(do (ns foo) (def x 1))`
defines `foo/x`, and a macro defined in a `do` may use a `def` made
before it there. Its value is the last form's, nil for `(do)`.
`disasm`, which runs nothing, compiles each top-level form whole. `(require 'my.app-core.foo)` maps the
name to `my/app_core/foo.nx` (dots to slashes, dashes to
underscores) and takes the first match on the load path (the CLI's
is the working directory, then the directory of the file being run).
The file's first form, as the reader reads it (comments and `#_`
discards before it, `^meta` on the name), must be `(ns my.app-core.foo
...)`, or nothing of the file runs; the
caller's namespace is restored afterwards. A namespace loads once; a
require of one still loading is `require: cyclic require of N`. The
namespaces the stdlib installs have no file (`markLoaded`), and
the Clojure library names `docs/STDLIB.md` §1 lists (`clojure.string`
and the rest) are namespaces sharing the Vars of their `nexis.*`
counterparts, so
`(require '[clojure.string :as str :refer [join]])` works. A file
that is missing, unreadable or does not compile is reported by the
loader's own diagnostic, located in that file when it has a place; a
file whose form fails at run time is `RequiredFileFailed` (§8).

## 3. Lexical shadowing of macros

A lexical binding shadows a macro, as it shadows an inlined core
operator in the compiler:

```clojure
(let* [when (fn [a b] [a b])]
  (when 1 2))   ; [1 2]: a call of the local, not the macro
```

`ExpandContext.lexical` counts, for each name, the binding forms
around the walk that bind it: `let*`, `loop*`, `fn*`, `letfn*` and
`catch` (and so the host macros that expand to them). Each opens a
`Scope` that adds its names and takes them out when it closes, so
whether a name is lexical is one lookup however deep the forms nest,
and macro lookup requires that it is not. Special forms cannot be
shadowed: they are recognised before the names are consulted. The
same table is `&env` (§1.3).

---

## 4. Auto-gensym for syntax-quote

A symbol ending in `#` inside syntax-quote stands for one fresh name
per syntax-quote form:

```clojure
`(let [x# 1] x#)
;; → (nexis.core/let [x__67__auto__ 1] x__67__auto__)
```

The reader emits only the marker; the gensym happens at expansion
time. Entering a `syntax_quote` Form opens a `GensymScope` mapping
`name#` to its generated `name__N__auto__`; every `name#` in that
form reuses it, and each syntax-quote form gets a scope of its own,
so a second expansion of the same source yields a different name.
The counter is process-wide, not per context: a generated name may
become a Var later forms see, so two expansions never share a name.
Host macros that need a fresh name (`and`, `or`, `case`, `condp`,
overloaded `fn`, destructuring, `try`) call `ctx.gensym`.

## 4b. SrcSpan / provenance for synthetic forms

- An input sub-form reused in the output keeps its own `origin`.
- A form a macro synthesizes takes the macro call's `origin`, so the
  `if` that `(when ...)` produces points at the `when`.
- A user macro's result, converted by `valueToForm`, keeps the place
  of each list, vector, map or set it took from the macro's arguments
  (`ExpandContext.arg_spans`, the arguments' non-empty collections by
  heap address, which the sub-VM's heap never collects or reuses
  during the call), so the body a `doseq` or `with-open` was given
  is reported where it is written; every other form of the result,
  and a symbol or scalar, which is not known by address, is at the
  call's span.

There is no separate "generated" origin: an error inside a form a
macro made is reported at the macro call. The `Builder` (§10b)
carries the call's span to every form it makes.

---

## 5. Syntax-quote / unquote / unquote-splicing

The reader emits these as `Datum.syntax_quote`, `unquote` and
`unquote_splicing`. Syntax-quote is built into the expander, not a
macro, and runs whenever an interner is present:

```text
sq(literal)          → literal
sq(symbol)           → (quote <qualified-symbol>)
sq(symbol#)          → (quote <gensym>)                 ; §4
sq(~x)               → x
sq(~@x)              → only inside a collection
sq((a b))            → (#%list sq(a) sq(b))
sq([a b])            → (#%vector sq(a) sq(b))
sq({k v})            → (#%map sq(k) sq(v))
sq(#{a})             → (#%set sq(a))
sq('x)               → (#%list 'quote sq(x))            ; `'a → (quote user/a)
sq(@x)               → (#%list 'nexis.core/deref sq(x))
sq(#(...))           → sq of the fn* form it stands for
sq(^m coll)          → (nexis.core/with-meta sq(coll) sq(m))  ; a list, vector, map or set
sq(^m x)             → (#%list 'nexis.internal/#%meta sq(x) sq(m))
sq(`x)               → sq(sq'(x))   ; the inner in a gensym scope of its own
```

A nested syntax-quote follows Clojure: the inner one becomes its
construction form first and the outer one quotes that, so in
`` `(a `(b ~~x)) `` the `~~x` is unquoted by the outer level and a
macro can write a macro:
`` (defmacro make-adder [name n] `(defmacro ~name [y#] `(+ ~y# ~~n))) ``.

The list a syntax-quoted `^m x` builds turns back into `^m x` when a
macro's result becomes a form, so `` `(def ^:private ~name 1) ``
defines a private Var although a symbol value carries no metadata. A
collection carries its metadata itself, as in Clojure:
`` (meta `^:foo [1 2]) `` is `{:foo true}`, and a list, vector, map
or set a macro returns with metadata becomes `^m coll` again, so the
metadata survives into the code the macro writes.

**Splicing.** Inside a collection with a `~@`, runs of ordinary
elements become `(#%list ...)` segments, each `~@x` a segment of its
own, joined by `(#%concat ...)`; a vector, map or set is rebuilt
from the list with `nexis.core/vec`,
`(nexis.core/apply nexis.core/hash-map ...)` or
`(nexis.core/apply nexis.core/hash-set ...)`. `coll:concat` accepts
every seqable (nil, list, vector, map as `[k v]` entries, set).

**Qualification** (PLAN §23 #29, Clojure's rule). An unqualified
symbol that resolves to a Var from the current namespace becomes that
Var's `ns/name`, its home namespace and its own name (a referred Var
qualifies to its home namespace, a `:rename`d one to its own name, as
in Clojure); one that names a host macro becomes `nexis.core/name`;
a symbol that resolves to nothing qualifies to the current namespace,
so
`` `(helper) `` written before `(defn helper ...)` still meets it.
Left bare: auto-gensyms, the special forms and `#%` names (§1.1),
`catch`, `finally`, `&`, `any`, and every name starting with `%`.
A qualified symbol keeps its prefix. Without a named namespace
nothing qualifies. A head qualified to `nexis.core` reaches the host
macro table, so `` `(let [x# 1] x#) `` expands through
`nexis.core/let` as `let` does; a symbol qualified to the current
namespace resolves like a bare one, forward references included.

A macro author meets the consequence first: a binding name written
bare inside syntax-quote, `` `(let [x ~a] x) ``, becomes `user/x`,
which cannot be bound. Write `x#` (fresh per expansion) or `~'x`
(deliberate capture), as in Clojure.

**Capture safety.** Syntax-quote output and host-macro output cannot
be captured by the user's bindings. Syntax-quote builds collections
with the `#%` special forms, which the compiler recognises before
any binding (`COMPILER.md` §4.3), and every core function a host
macro's output calls is the qualified `nexis.core/name` (§10b):
destructuring uses `nexis.core/nth`, `nthnext`, `get` and `seq?`,
and a keyword or symbol key looks itself up, which nothing binds;
`case` `=`; `defrecord` `=`, and a field is a keyword lookup;
`case` and `condp` report through `str`; `@x` is `deref`, in a
macro's arguments too. So
`(let [nth (fn [& _] :captured)] (let [[a b] [1 2]] [a b]))` is
`[1 2]`, and a `(defn nth ...)` in the user's namespace changes
nothing. A qualified `nexis.core/+` is still inlined (`COMPILER.md`
§4.3), so the qualification costs nothing. The macros a host macro's
output invokes are qualified the same way, since a local or an
ns-local macro or Var of the name would otherwise capture the head
(§3): `nexis.core/let` (destructuring in `fn`, `loop` and record
methods), `nexis.core/fn` (`defn`, method impls),
`nexis.core/defn` and
`nexis.core/and` (`defrecord`), so `(defn f [let] (fn [[a b]]
[let a b]))` and `(defmacro and ...)` before a `defrecord` work as in
Clojure. Only special-form heads (`let*`, `fn*`, `loop*`, `if`, `do`,
`def`, `recur`, `throw`, `quote`, `var`) and the clause words
`catch` and `any` stay bare: no binding can shadow them.

---

## 6. Fixed-point loop termination

`MAX_EXPANSION_DEPTH` is 256: the number of expansions in a row at
one position, a macro call whose expansion is again a macro call.
The sub-forms of an expansion start again at 0, so source nesting
(300 nested `let`s) never counts. Past the limit the expander raises
`ExpansionDepthExceeded`, reported as `CompileError.MacroDepthExceeded`:

```clojure
(defmacro broken [x] `(broken ~x))
(broken 1)   ; MacroDepthExceeded: macro expansion did not finish after 256 expansions in a row
```

Nesting is bounded by the native stack guard (`src/stack.zig`,
`VM.md` §13.1): every recursion of the expander over a form (the
walk, syntax-quote, `#()` scanning, destructuring and the Form ↔
Value conversions) checks it, and a form nested past the budget is
`ExpansionDepthExceeded` too, "form nested too deeply", never a
fault.

---

## 7. Quoting + macroexpansion ordering

`(quote x)` is opaque: `(quote (when x y))` does not expand `when`
and yields the list `(when x y)` at run time (`COMPILER.md` §5.1).

---

## 8. CompileError vs ExpandError

| `ExpandError` | Reported as `CompileError` |
|---|---|
| `ExpansionDepthExceeded` | `MacroDepthExceeded` |
| `MalformedMacroCall` | `MacroExpansionFailure` |
| `RequiredFileFailed` | `RequiredFileFailed` |
| `ControlTransferred` | `ControlTransferred` |
| `OutOfMemory` | `OutOfMemory` |

`RequiredFileFailed` and `ControlTransferred` are not expansion
errors: the loader returns them when a `require`d file's form failed
at run time with no handler in force, or threw to a handler of the
running program, and they pass through under their own names so
`eval` and the CLI report a runtime failure as one (`COMPILER.md`
§7, `TOOLING.md` §1).

Every expansion error but out-of-memory records
`ExpandContext.failure`: the span of the innermost form that failed
and a message. The compiler hands it out through
`CompileOptions.out_detail`, the CLI prints it after the error name,
and `eval` puts it under `:detail`.

| Failure | Span | Message |
|---|---|---|
| A user macro throws | the call | `macro m threw <what>`: an error map's `:error` and `:message` (`:kind-mismatch: + expects numbers, got nil`), either alone when it has one, an `ex-info` map's `:message`, a string, a keyword |
| … fails in the VM | the call | `macro m failed: ArityMismatch: ...` (the VM's detail when it has one) |
| … gets the wrong number of arguments | the call | `macro m takes 1 argument, got 0`, the counts named as a call's arity error names them (`VM.md` §13): `macro m takes at least 2 arguments, got 1`, `macro m takes 1 or at least 3 arguments, got 2` |
| … returns a non-form | the call | `a macro returned a function, which is not a form` |
| An argument a macro cannot take | the argument | `a syntax-quote is not data a macro can take` |
| A binding form's vector | the vector | `let: the binding vector needs an even number of forms` |
| A pattern that cannot bind | the pattern | `cannot bind an integer` |
| Too many expansions in a row (§6) | the form | `macro expansion did not finish after 256 expansions in a row` |
| Nesting past the stack guard (§6) | the innermost list | `form nested too deeply` |
| Any other malformed form | the form | a message naming it, e.g. `if: expected a test, a then and an optional else`, `malformed (when ...)` |

A macro call of the wrong shape (`(when)`) is
`MacroExpansionFailure`. The lowering errors `MalformedForm`,
`ExpectedSymbol` and `ExpectedVector` are the compiler's, for
special-form shapes the expander passes through.

---

## 9. `#(...)` anonymous functions

The reader emits `#(body...)` as `Datum.anon_fn`; the expander
rewrites it:

```
#(+ % %2)     → (fn* [%1 %2] (+ %1 %2))
#(inc %)      → (fn* [%1] (inc %1))
#(apply f %&) → (fn* [& %&] (apply f %&))
```

1. Scan the body for placeholders: `%` is positional 1, `%N`
   positional N (N ≥ 1), `%&` the rest parameter. Every sub-form is
   scanned (lists, vectors, maps, sets, `@x`, `^meta`, the unquotes
   of a syntax-quote) except a quoted one.
2. The parameters are `%1` through the highest N found, then
   `& %&` when the rest is used.
3. `%` is rewritten to `%1` and the result is `(fn* params (body...))`.

Nested `#()` never reaches the expander: the reader rejects it.

---

## 10. Host macro table

`defaultMacros(allocator)` installs these; the CLI's `run` and
`repl` compile with it.

| Macro | Expands to |
|---|---|
| `let` | `let*` with destructuring: a vector pattern binds each element by `nth`, `& r` to `(nthnext src i)`, the seq of the source past the `i` elements before it (so `(let [[a & r] [1]] r)` is nil and `(let [[& r] [1 2]] r)` is `(1 2)`, as in Clojure) and `:as` to the source; a map pattern binds `{a :k}`, `:keys` / `:strs` / `:syms` vectors (an entry's own namespace or a `:p/keys` group namespace qualifies the key; a keyword entry in `:keys` is the key), `:or` defaults for an absent key and `:as`, bound before the keys so a default may read it; a keyword or quoted symbol key is called on the source, `(:k src)` or `(:k src default)`, `get`'s lookup in one instruction (`COMPILER.md` §4.3), and any other key is `(nexis.core/get src key default?)`; a map pattern over a seq, a lazy one included, takes it as keyword arguments, as Clojure 1.12 does: `(if (seq? src) (nexis.internal/#%kwargs src) src)`, where `#%kwargs` builds the map from alternating keys and values or is the one trailing map; patterns nest; plain symbols pass through. |
| `fn` | `fn*` with destructured params: a pattern param becomes a gensym and the body is wrapped in a destructuring `let`; so a map pattern after `&` takes keyword arguments (`let`'s rule for a map pattern over a seq; with no arguments the rest is nil, and so is its `:as`). Overload clauses `(fn name? ([x] ...) ([x y] ...) ([x & r] ...))` lower to `fn*`'s own clauses, `(fn* name? ([x'] ...) ([x' y'] ...) ([x' & r'] ...))`, each clause's params and body as a one-clause `fn`'s; the compiler makes each a routine over one arity table and a call enters the clause its argument count picks, an exact fixed arity before the variadic clause, whose rest is nil when it gets no argument past its fixed params (`COMPILER.md` §5.5, `VM.md` §6). The compiler checks Clojure's clause rules (`COMPILER.md` §5.5). A `recur` in a clause re-enters that clause (a variadic clause's rest param receives the one seq passed), a pattern param destructures again on every iteration, a `recur` count that differs from the clause's param count is `RecurArityMismatch`, and a `loop` inside the clause owns the `recur`s in its body. A count no clause takes is `ArityMismatch`, `:arity-mismatch` when caught. A named `fn` may call itself. A body whose first form is a map with `:pre` and/or `:post` vectors, followed by more forms, is a condition map, as in Clojure: each `:pre` condition is checked before the body and each `:post` after it with `%` bound to the result; a failure raises `(nexis.internal/#%raise :assertion-failed "Assert failed: <condition>")`, the error map of `VM.md` §13 with its place keys at the condition. |
| `defn` | `(def ^{meta} name (fn name ...))`, so params destructure and overloads work as for `fn`. `^meta` on the name, a docstring after it (`:doc`), an attribute map after that and the `:arglists` land on the Var, and `def` adds the Var's `:name` and `:ns` (the namespace's name symbol), as Clojure does: `(defn f "doc" {:k 1} [x] ...)` → `(let* [v# (def f (fn f [x] ...))] (nexis.core/reset-meta! v# {:doc "doc" :k 1 :arglists (quote ([x])) :name (quote f) :ns (quote user)}) v#)`. `def` and `defmacro` take `^meta` and a docstring the same way, and every `def` sets `:name` and `:ns`. A name qualified with the current namespace (`(def user/x 1)` in `user`) is the bare name. |
| `defn-` | `defn` with `:private true` in the Var's metadata, which `(require '[ns :refer :all])` skips. |
| `loop` | `loop*`; each pattern binds a gensym and destructures again on every iteration, so `recur` rebinds the gensyms. |
| `when`, `when-not` | `(if test (do body...) nil)`, `(if test nil (do body...))` |
| `and` | `(and)` → `true`; `(and x)` → `x`; `(and x y ...)` → `(let* [g x] (if g A g))`, `A` the same expansion of `(and y ...)`, the whole chain built in one step from the last operand back: the first falsy value or the last. |
| `or` | `(or)` → `nil`; `(or x)` → `x`; `(or x y ...)` → `(let* [g x] (if g g O))`, `O` the expansion of `(or y ...)`, built the same way: the first truthy value or the last. |
| `cond` | Nested `if`; an odd argument count fails. `:else` works by truthiness: a last test that is a truthy literal (a keyword, `true`, a number, a string, a char) is no test, its value the innermost `else`. |
| `case` | Keys are constants, never evaluated: a symbol key is that symbol, a vector or map key that literal, a list `(k1 k2)` groups alternatives; they are compared with `=`. With fewer than three constants, `(let* [g expr] (if (= g 'k1) v1 ...))`; with three or more, one hashed lookup finds the clause, `(let* [g expr i (get '{k1 0 k2 1 ...} g -1)] (if (== i 0) v1 (if (== i 1) v2 ...)))`, each test one inlined compare (`g` is bound only when there is no default, for the throw). The map's lookup is `=`'s equality and hash. Two constants that are `=` but spelled differently (`[1]`, a grouped `(1)`) would share a key where the chain lets the first clause win, so a case with two compound constants, or two bignums, keeps the chain. The map lists the constants in clause order, so they are interned in source order, ahead of the clauses' results. A constant given twice, alone or in a group, is `MalformedMacroCall` "case: duplicate test constant" at the second, as in Clojure; constants of different kinds (`1`, `1.0`, `\1`) are distinct. With no trailing default, no match throws `{:error :no-matching-clause :message "No matching clause: <expr>" :value expr}`. |
| `condp` | `pred` and `expr` evaluated once; clauses become `(if (p c e) v ...)` with `case`'s default policy. A clause `c :>> f` calls `f` on the predicate's truthy result. |
| `->`, `->>` | Thread the value as the first (`->`) or last (`->>`) argument of each step, left to right; a step that is not a list is called with the value alone; an empty-list step fails. |
| `defrecord` | Registers the record type and defines `T-type-id`, `->T`, `map->T`, `T?` and one impl per method under the protocol named by the preceding bare symbol, its arities written `(m [params] body) (m [params] body)` or `(m ([params] body) ...)` and gathered into one overloaded `fn` (`PROTOCOLS.md` §4.2). `T` itself is bound to the record's type, the symbol `ns.T` (`(def T 'ns.T)`), which is the form's value (`PROTOCOLS.md` §0). An inline method sees the record's fields as locals unless a parameter shadows one: `(defrecord Rect [w h] Shape (area [_] (* w h)))`. `DeclaredNames` knows the defined names, so a form may refer to `->T` before the `defrecord`. |
| `defprotocol` | `(do (def IFoo (nexis.internal/#%register-protocol "<ns>/IFoo" [:bar ...])) (def bar (nexis.internal/#%protocol-fn IFoo :bar)) ... 'IFoo)`, whose value is the name `IFoo`; a docstring before the methods becomes `IFoo`'s `:doc`, and `:option value` pairs there are ignored; a method's parameter vectors become its Var's `:arglists` and a docstring among them its `:doc` (`PROTOCOLS.md` §4.1). |
| `extend-type`, `extend-protocol` | Install impls in the protocol registry, a method's arities spelled as for `defrecord` (`PROTOCOLS.md` §4.2–4.3). |

**Macros written in nexis.** The embedded stdlib files define more
with `defmacro` (`STDLIB.md` §1):

- `core.nx`: `if-let`, `when-let`, `if-some`, `when-some`,
  `when-first`, `if-not`, `comment` (nil; the body is never
  compiled), `doto`, `defonce`, `assert`, `time`, `with-out-str`,
  `dotimes`, `while`, `for` (Clojure 1.12's: a lazy seq, one
  iterator per binding, the innermost walking a chunk at a time where
  its coll is chunked, `:let`, `:when` and `:while` inside the chunk;
  one binding and no modifiers is `map`, `docs/LAZY.md` §7), `doseq`
  (`for`'s modifiers, for effect, yielding nil), `letfn`, `declare`, `doc` and `dir`
  (`STDLIB.md` §10), `cond->`, `cond->>`, `some->`, `some->>`,
  `as->`, `vswap!`, `binding` (`(do (push-thread-bindings ...) (try
  body (finally (pop-thread-bindings))))`, `VM.md` §6.5),
  `with-tx`, `with-read-tx`, `with-snapshot` (`DB.md`), `defmulti`
  (defines the Var once, the docstring and attr-map merged into its
  metadata; a lone trailing option or one other than `:default` and
  `:hierarchy` fails the expansion with Clojure's message) and
  `defmethod` (`(add-method mf dispatch-val (fn fn-tail...))`),
  `STDLIB.md` §9.
- `nextomic.nx`: `with-conn` (`NEXTOMIC.md`).
- `test.nx`: `deftest`, `is`, `testing` (`TOOLING.md` §3).

## 10b. Form construction

A host macro builds its output with a `Builder`: the context and the
call's span, which every synthetic form carries (§4b).

```zig
const b = Builder{ .ctx = ctx, .origin = call_form.origin };
// (when t body...) → (if t (do body...) nil)
return b.list(.{ "if", args[0], try b.list(.{ "do", args[1..] }), null });
```

`list`, `vec` and `map` take a tuple whose elements are forms,
slices of forms (spliced in place), integers, booleans, `null`
(nil) or strings: `":k"` is a keyword, `"ns/name"` a qualified
symbol and any other string a symbol. `b.kw(name)` makes a keyword
from a run-time name and `b.gensym(base)` a fresh symbol (§4). Every
core function a host macro's output calls is written qualified,
`"nexis.core/nth"` (§5).
