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
| `failure` | the span and message of the innermost failure (§8) |

`ctx.gensym(base)` makes `<base>__<N>__auto__` (§4).

### 1.1 Lookup order in `expandList`

For a list whose head is an unqualified symbol:

1. **Special forms** (§2b) come first, are never macros and cannot
   be shadowed: the keys of `expand.special_forms` (`quote`, `var`,
   `if`, `do`, `recur`, `throw`, `let*`, `loop*`, `fn*`, `letfn*`,
   `def`, `set!`, `try`, `defmacro`, `ns`, `require`), each with its
   own walker, and every `#%` name (`#%list`, `#%concat`, ...),
   whose arguments expand as a call's do.
2. A name bound in the lexical `ExpandEnv` is an ordinary call (§3).
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
   become the Var's metadata, parameters destructure and overload
   clauses dispatch on argument count, as for `fn`. The expander
   builds `(def name (fn name ...))` (wrapped to set the metadata as
   `defn` does), expands it in the enclosing env, compiles and runs
   it through `ctx.compile_eval` in a fresh sub-VM, and sets the
   Var's `macro` flag. The form is replaced by `(var name)`, so the
   REPL prints `#'name`.
3. **Invocation**: the argument count is checked against the macro
   function's arity, each argument Form becomes a Value
   (`formToValue`), and a fresh sub-VM (an idle routine, the
   compile-time interner, the calling VM's heap, collection off,
   `ctx.io`) calls the macro function through `callValue`. Its
   result becomes a Form at the call's span (`valueToForm`), or its
   throw or VM error becomes the failure message (§8). The sub-VM is
   released and the result is expanded again in the call's place.
4. **A fresh sub-VM per call**: no handler, finally or halted state
   to save and restore. The macro routine's Var table points into
   the caller's namespace and its constants are caller-interned, so
   the sub-VM needs no namespace of its own.
5. **Persistent storage**: `compile_eval` allocates the macro
   function from `CompileOptions.persistent_allocator` (the VM's
   runtime arena for the CLI and the REPL), so the closure outlives
   the per-form compile arena.
6. **Form ↔ Value.** Form → Value (`formToValue`): nil, booleans,
   integers (a fixnum, or a bignum past the fixnum range or for a
   `bigint`), reals, chars, strings, symbols and keywords (interned,
   qualified by their full name), lists, vectors, maps and sets;
   `'x` as `(quote x)`, `@x` as `(deref x)`, `#()` as the `fn*`
   form it stands for, and `^m x` as `x` (the metadata is dropped).
   Only a syntax-quote, unquote or unquote-splicing is refused, as
   `MalformedMacroCall` at the argument. Value → Form
   (`valueToForm`): nil, booleans, fixnums, bignums (an `int` within
   i64, else a `bigint`), floats, chars, strings, symbols, keywords,
   lists (including a vector's seq view), vectors, maps and sets; the
   list `(nexis.internal/#%meta x m)` becomes `^m x` (§5). Any other
   kind (a function, a Var, an atom) is `MalformedMacroCall`.
7. **Variadic macros** (`& body`) work; `recur` in a variadic macro
   body is rejected as at run time.
8. Macro arguments are **unevaluated forms as data**: a macro body
   inspects them with the core natives (`first`, `rest`, `cons`,
   `list`, `count`, `nth`, `seq?`, ...) and builds its output with
   syntax-quote or those natives.
9. **The expander at run time.** The natives reach the compiler
   through `vm.CompilerHooks` (`compile.RuntimeHooks`, installed by
   the runtime that boots the VM) and build their values on the VM
   heap; a VM without hooks throws `:no-compiler`.
   - `(macroexpand-1 form)` is one macro step (`expandOnce`: a user
     or host macro at the head, never a special form or `#%`
     primitive; the raw output, nothing inside it expanded, no
     lexical environment), or the form itself. `macroexpand` repeats
     it until the head is not a macro. A failure throws
     `:macro-expansion-failure`.
   - `(read-string s)` reads the first form of `s` as data; a reader
     error throws `:reader-error`.
   - `(eval form)` converts the value to a Form, then compiles it as
     the REPL compiles a line: the current namespace, the registry,
     interner, host macros and loader, a fresh set of declared
     names. It runs the routine on the calling VM as a nested call
     (`vm.runRoutine`) and returns its value. A `def` inside binds
     in the current namespace, a `defmacro` serves a later `eval`,
     `(ns ...)` switches the current namespace, a returned closure
     stays callable, a dynamic binding in force is seen, and `eval`
     nests. The form has no lexical environment: a caller's
     `let`-bound name is `UnresolvedSymbol` inside it. The Form and
     Tiny trees live in a scratch arena freed when `eval` returns;
     the routine, its constants and every closure prototype live in
     the VM's runtime arena. A value that is not a form (a list
     holding a function) and a form that does not compile throw
     `{:error :compile-error :message "<CompileError name>" :form
     form}`, plus `:detail` with the expander's reason when it gave
     one, so `(catch :compile-error e ...)` takes it and
     `ex-message` reads the name (`"UnsupportedForm"` for a
     non-form). A throw inside the evaluated form propagates as an
     ordinary throw.
   - Syntax-quote is not data at run time: a quoted form holding one
     is `UnsupportedFeature` at compile and `read-string` rejects
     it, so a form built for `eval` uses `list`, `cons` and quote.

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
| `let*`, `loop*` | Binding names are not expanded. Each right-hand side expands in the env of the bindings before it; the body with all of them. |
| `fn*` | The parameter vector and self-name are not expanded; the body expands with the params, rest param and self-name in the env. |
| `letfn*` | Names and parameter vectors are not expanded. Every name enters the env first; each function body expands with that env plus its params; then the body. |
| `def` | The name is not expanded and does not enter the env (Vars are not lexical); the value expands. |
| `var` | Opaque. |
| `if`, `do`, `recur`, `throw`, `#%` constructors, ordinary calls | Every sub-form expands in the current env. |
| `set!` | `(set! target v)` → `(nexis.core/var-set (var target) v)` with `v` expanded. `target` must be a symbol; one bound in the lexical env is refused (a local has no thread binding). The Var's own checks (`:not-dynamic`, `:no-thread-binding`) happen at run time (`VM.md` §6.5). |
| `try` | `(try body* (catch M b h*)* (finally f*)?)` becomes the primitive `(try body* (catch any g <chain>) (finally f*)?)`. The chain tries the clauses in order, `(if (nexis.internal/#%catch-matches? g M) (let* [b g] h*) ...)`, and ends in `(throw g)`, so a value no clause takes unwinds through the `finally`. A matcher is `any`, any other symbol (a class name such as `Exception`, taken as `any` since nexis has no classes), `:default` (also `any`), or a keyword `:tag`, which takes a thrown value equal to `:tag`, a map or record whose `:error` is `:tag`, or an `ex-info` map whose data's `:error` is `:tag`. Any other matcher, a catch or finally before the body's end, or a binding that is not an unqualified symbol is `MalformedMacroCall`. No clause: a finally-only `try`; neither clause: `(do body*)`. The body, each handler (its binding in the env) and the finally body expand; matchers and bindings do not. |
| `defmacro` | §1.2; replaced by `(var name)`. |
| `ns` | `(ns NAME "doc"? {attrs}? clause*)` switches `registry.current` to `NAME` at expansion time, creating it (parent `nexis.core`) when unregistered, then runs each `(:require spec*)` clause as `require` does. `(:refer-clojure :exclude [names])` interns each name `nexis.core` or the host macro table holds as an unbound Var of the namespace, so the name resolves, inlines and expands as the namespace's own from then on (a use before the namespace defines it is `:unbound-var` at run time; `nexis.core/name` still reaches core's); `(:refer-clojure)` alone does nothing, and `:only` or `:rename` is `MalformedMacroCall`. `(:gen-class)` is accepted and does nothing; the docstring and attribute map are accepted and not kept; any other clause (`:import`, `:use`) is `MalformedMacroCall`. Replaced by `nil`. |
| `require` | `(require spec*)`: each spec, quoted or not, is `ns-name` or `[ns-name option*]`, loaded at expansion time through `load_callback` and replaced by `nil`. `:as a` aliases the namespace; `:as-alias a` aliases it without loading; `:refer [x y]` maps `x` and `y` in the current namespace to that namespace's Vars (the same Vars: a later `def` there is seen here); `:refer :all` maps every Var not marked `:private`; `:rename {x z}` names a referred `x` as `z`. A keyword spec (`:reload`) is a flag and changes nothing. Referring a name the current namespace defines itself, and `def` of a name that refers to another namespace's Var, are `MalformedMacroCall` (Clojure's rule); a missing Var or unknown option is reported by name. |
| Non-symbol head | An ordinary call: head and arguments expand. |
| `^meta` | On a vector, map or set literal: `(nexis.core/with-meta coll {meta})`, the map evaluated like any map literal except that a symbol under `:tag` is quoted, so `(meta ^:foo [1])` is `{:foo true}`. On anything else in expression position (a symbol, a call) it is a hint and is dropped. In every binding position (`let`, `loop`, `let*`, `loop*`, `fn` and `fn*` names and patterns, a parameter vector as a return hint, `:keys` entries, `defrecord` fields, a `catch` binding) it is dropped: `(defn f ^long [^String s] ...)` is `(defn f [s] ...)`. On the name of `def`, `defn` or `defmacro` it becomes the Var's metadata, `^String` as `{:tag String}` with the tag quoted. |

Every sub-form is expanded exactly once, so a user macro runs once
per call site. `ExpandEnv` tracks lexical names with an
innermost-first parent walk, as `compile.LowerEnv` does.

**The loader** (`src/loader.zig`). `require` reaches it through
`load_callback`. `Loader.evalSource` is the one path from text to
effect for `run`, `repl`, `disasm`, the stdlib bootstrap and
`require`: parse, read, declare the names the text defines, compile
and run each top-level form. `(require 'my.app-core.foo)` maps the
name to `my/app_core/foo.nx` (dots to slashes, dashes to
underscores) and takes the first match on the load path (the CLI's
is the working directory, then the directory of the file being run).
The file's first form must be `(ns my.app-core.foo ...)`; the
caller's namespace is restored afterwards. A namespace loads once; a
require of one still loading is `require: cyclic require of N`. The
namespaces the stdlib installs have no file (`markLoaded`), and
`clojure.string`, `clojure.set`, `clojure.test` and `clojure.pprint`
are namespaces sharing the Vars of their `nexis.*` counterparts, so
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

`ExpandEnv` holds the names bound by `let*`, `loop*`, `fn*`,
`letfn*` and `catch` (and so by the host macros that expand to
them), and macro lookup requires `!env.contains(name)`. Special
forms cannot be shadowed: they are recognised before the env is
consulted.

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
`for`, overloaded `fn`, destructuring, `try`) call `ctx.gensym`.

## 4b. SrcSpan / provenance for synthetic forms

- An input sub-form reused in the output keeps its own `origin`.
- A form a macro synthesizes takes the macro call's `origin`, so the
  `if` that `(when ...)` produces points at the `when`.
- A user macro's result, converted by `valueToForm`, is entirely at
  the call's span.

There is no separate "generated" origin: an error inside macro
output is reported at the macro call. The `Builder` (§10b) carries
the call's span to every form it makes.

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
symbol becomes `ns/name`, where `ns` is the namespace whose own Var
it names, searched from the current namespace along its parent chain
(`nexis.core` last), or `nexis.core` when it names a host macro; a
symbol nothing holds qualifies to the current namespace, so
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
destructuring uses `nexis.core/nth`, `next` and `get`; overload
dispatch `count`, `=`, `<`, `not` and `next`; `case` `=`; `for`
`seq`, `first`, `next` and `conj`; `defrecord` `get` and `=`;
`case` and `condp` report through `str`; `@x` is `deref`, in a
macro's arguments too. So
`(let [nth (fn [& _] :captured)] (let [[a b] [1 2]] [a b]))` is
`[1 2]`, and a `(defn nth ...)` in the user's namespace changes
nothing. A qualified `nexis.core/+` is still inlined (`COMPILER.md`
§4.3), so the qualification costs nothing. The macros a host macro's
output invokes are qualified the same way, since a local or an
ns-local macro or Var of the name would otherwise capture the head
(§3): `nexis.core/let` (destructuring in `fn`, `loop`, `for` and
record methods), `nexis.core/fn` (`defn`, overloads, method impls),
`nexis.core/loop` (overload clauses), `nexis.core/defn` and
`nexis.core/and` (`defrecord`), so `(defn f [let] (for [[a b] xs]
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
| A user macro throws | the call | `macro m threw <message>`: an `ex-info` or error map's `:message`, a string, a keyword |
| … fails in the VM | the call | `macro m failed: ArityMismatch: ...` (the VM's detail when it has one) |
| … gets the wrong number of arguments | the call | `macro m takes 1 argument, got 0` |
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
| `let` | `let*` with destructuring: a vector pattern binds each element by `nth`, `& r` to `next` of the source past the elements before it (so `(let [[a & r] [1]] r)` is nil, as `nthnext` gives in Clojure) and `:as` to the source; a map pattern binds `{a :k}`, `:keys` / `:strs` / `:syms` vectors (an entry's own namespace or a `:p/keys` group namespace qualifies the key; a keyword entry in `:keys` is the key), `:or` defaults for an absent key and `:as`; patterns nest; plain symbols pass through. |
| `fn` | `fn*` with destructured params: a pattern param becomes a gensym and the body is wrapped in a destructuring `let`; a map pattern after `&` takes keyword arguments (the rest seq becomes the map `nexis.internal/#%kwargs` builds from alternating keys and values or one trailing map). Overload clauses `(fn name? ([x] ...) ([x y] ...) ([x & r] ...))` lower to one variadic `fn*` that binds the argument count and tests the fixed arities in source order, then the variadic clause, then throws `:arity-mismatch`; a clause's rest is `next` of the arguments past its fixed params, so an empty rest is nil for every `fn` (`VM.md` §6); at most one variadic clause, with no fixed arity above it and none repeated (Clojure's rules). Each clause binds its params through `loop`, so `recur` in a clause's tail re-enters that clause (a variadic clause's rest param receives the one seq passed), a pattern param destructures again on every iteration, a `recur` count that differs from the clause's param count is `RecurArityMismatch`, and a `loop` inside the clause owns the `recur`s in its body. A named `fn` may call itself. A body whose first form is a map with `:pre` and/or `:post` vectors, followed by more forms, is a condition map, as in Clojure: each `:pre` condition is checked before the body and each `:post` after it with `%` bound to the result; a failure throws `{:error :assertion-failed :message "Assert failed: <condition>"}`. |
| `defn` | `(def name (fn name ...))`, so params destructure and overloads work as for `fn`. `^meta` on the name, a docstring after it (`:doc`) and an attribute map after that land on the Var: `(defn f "doc" {:k 1} [x] ...)` → `(let* [v# (def f (fn f [x] ...))] (nexis.core/reset-meta! v# {:doc "doc" :k 1 :arglists (quote ([x]))}) v#)`; with none of them the Var's metadata stays nil. `def` and `defmacro` take `^meta` and a docstring the same way. |
| `defn-` | `defn` with `:private true` in the Var's metadata, which `(require '[ns :refer :all])` skips. |
| `loop` | `loop*`; each pattern binds a gensym and destructures again on every iteration, so `recur` rebinds the gensyms. |
| `when`, `when-not` | `(if test (do body...) nil)`, `(if test nil (do body...))` |
| `and` | `(and)` → `true`; `(and x)` → `x`; `(and x y ...)` → `(let* [g x] (if g (and y ...) g))`: the first falsy value or the last. |
| `or` | `(or)` → `nil`; `(or x)` → `x`; `(or x y ...)` → `(let* [g x] (if g g (or y ...)))`: the first truthy value or the last. |
| `cond` | Nested `if`; an odd argument count fails. `:else` works by truthiness. |
| `case` | `(let* [g expr] (if (= g 'k1) v1 ...))`. Keys are constants, never evaluated: a symbol key is that symbol, a vector or map key that literal, a list `(k1 k2)` groups alternatives; compared with `=`, not hashed. A constant given twice, alone or in a group, is `MalformedMacroCall` "case: duplicate test constant" at the second, as in Clojure; constants of different kinds (`1`, `1.0`, `\1`) are distinct. With no trailing default, no match throws `{:error :no-matching-clause :message "No matching clause: <expr>" :value expr}`. |
| `condp` | `pred` and `expr` evaluated once; clauses become `(if (p c e) v ...)` with `case`'s default policy. A clause `c :>> f` calls `f` on the predicate's truthy result. |
| `for` | Eager: one `loop*` per binding pair, each pair followed by any number of `:let [b]`, `:when t` and `:while t`; a pattern destructures through `let`. `:when` skips the element, `:while` ends the loop it follows (outer loops carry on). The loops fill a vector returned as a seq, `()` when empty: a list, as Clojure's `for` gives, built eagerly (PLAN §23 #14). |
| `->`, `->>` | Thread the value as the first (`->`) or last (`->>`) argument of each step, left to right; a step that is not a list is called with the value alone; an empty-list step fails. |
| `defrecord` | Registers the record type and defines `T-type-id`, `->T`, `map->T`, `T?` and one impl per method under the protocol named by the preceding bare symbol, its arities written `(m [params] body) (m [params] body)` or `(m ([params] body) ...)` and gathered into one overloaded `fn` (`PROTOCOLS.md` §4.2). `T` itself is not bound. An inline method sees the record's fields as locals unless a parameter shadows one: `(defrecord Rect [w h] Shape (area [_] (* w h)))`. `DeclaredNames` knows the defined names, so a form may refer to `->T` before the `defrecord`. |
| `defprotocol` | `(do (def IFoo (nexis.internal/#%register-protocol "<ns>/IFoo" [:bar ...])) (def bar (nexis.internal/#%protocol-fn IFoo :bar)) ...)`; a docstring and `:option value` pairs before the methods are ignored, as are method signatures past the name (`PROTOCOLS.md` §4.1). |
| `extend-type`, `extend-protocol` | Install impls in the protocol registry, a method's arities spelled as for `defrecord` (`PROTOCOLS.md` §4.2–4.3). |

`&form` and `&env` are not passed to any macro (PLAN §23 #34).

**Macros written in nexis.** The embedded stdlib files define more
with `defmacro` (`STDLIB.md` §1):

- `core.nx`: `if-let`, `when-let`, `if-some`, `when-some`,
  `when-first`, `if-not`, `comment` (nil; the body is never
  compiled), `doto`, `defonce`, `assert`, `time`, `with-out-str`,
  `dotimes`, `while`, `doseq` (`for`'s modifiers, for effect,
  yielding nil), `letfn`, `declare`, `doc` (prints a Var's
  `:arglists` and `:doc`), `cond->`, `cond->>`, `some->`, `some->>`,
  `as->`, `vswap!`, `binding` (`(do (push-thread-bindings ...) (try
  body (finally (pop-thread-bindings))))`, `VM.md` §6.5),
  `with-tx`, `with-read-tx`, `with-snapshot` (`DB.md`).
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
