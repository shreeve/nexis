# MACROEXPAND.md — the macroexpander

Authoritative contract for `src/expand.zig`: expansion semantics,
the execution model (host-Zig macros and user `defmacro`),
syntax-quote and auto-gensym, the special-form traversal rules and
the error model. Derivative from [`PLAN.md`](../PLAN.md) §6.1
(primitive core), §14.1-14.2 (macros + syntax-quote) and
[`CLOJURE-REVIEW.md`](../CLOJURE-REVIEW.md) §1.1 (compiler-primitive
`*` convention + two-stage bootstrap). Companion:
[`COMPILER.md`](COMPILER.md) (what consumes the expander's output).

---

## 0. Where the macroexpander sits

The macroexpander is a **Form → Form rewriter** that fires
between `Reader.readOneForm` and `lowerForm`:

```
source bytes
   → parser.parseProgram   →  Sexp tree
   → Reader.readProgram    →  []const *Form
   → macroexpand           →  []const *Form  ← THIS DOC
   → lowerForm             →  *Tiny
   → compileTinyWithNamespace
   → bytecode
   → VM
```

It walks each top-level form, recursively expands any macro
calls it finds in operator position, and emits a new Form tree
whose `lowerForm` shape is what the rest of the pipeline
understands. **It produces no new Form datums** — the output is
a subset of the input's `Datum` taxonomy: `syntax_quote`,
`unquote`, `unquote_splicing` and `anon_fn` are rewritten away.

The macroexpander is the **first place quoted-compound output
appears**: `(when test body...)` expands to
`(if test (do body...) nil)`, constructed as a Form list with
synthesized `if`/`do`/`nil` sub-forms. Quoted symbols in macro
output compile through `Tiny.literal` and the shared `Interner`
(`COMPILER.md` §3).

---

## 1. Execution model

Macros come in two kinds, dispatched from one lookup:

- **Host-Zig macros**: callback functions in a `HostMacroTable`,
  installed by `defaultMacros` (§10).
- **User macros**: Vars with `macro = true`, defined by `defmacro`
  and executed at expansion time in a sub-VM (§1.2).

```zig
pub const ExpandContext = struct {
    allocator: std.mem.Allocator,
    interner: *intern_mod.Interner,
    host_macros: *const HostMacroTable,
    namespace: ?*vm_mod.Namespace = null,          // user-macro lookup
    compile_eval: ?CompileEvalContext = null,      // defmacro evaluation
    registry: ?*vm_mod.NamespaceRegistry = null,   // ns / qualified macros
    load_callback: ?LoadCallback = null,           // (require ...)
    value_heap: ?*heap_mod.Heap = null,            // where macro args live
    failure: ?Failure = null,                      // why and where it failed (§8)
};

pub const MacroFn = *const fn (
    ctx: *ExpandContext,
    call_form: *const reader.Form,    // the (when x y) form being expanded
    args: []const *reader.Form,        // the args after the head: [x, y]
) ExpandError!*reader.Form;       // returns the rewritten form

pub const HostMacroTable = std.StringHashMapUnmanaged(MacroFn);
```

The compiler builds a context for each top-level form.

### 1.1 Lookup order in `expandList`

For a list form `(head ...)` whose head is an unqualified symbol:

1. **Special forms** (§2b) are recognized first and are never
   shadowable or macro-overridable: `quote`, `syntax_quote`
   (a datum), `let*`, `loop*`, `fn*`, `letfn*`, `def`, `defn`,
   `var`, `recur`, `do`, `if`, `try`, `throw`, `defmacro`, `ns`,
   `require`, and the internal constructors `#%list` / `#%concat`
   / `#%vector` / `#%map` / `#%set` (whose arguments ARE
   expanded).
2. If the name is bound in the lexical `ExpandEnv` → ordinary
   call (§3).
3. **User macro**: `ctx.namespace.lookup(name)` yields a Var with
   `macro = true` and `bound = true` → §1.2.
4. **Host macro**: `ctx.host_macros.get(name)` → call the
   `MacroFn`, then recursively expand its result.
5. Otherwise an ordinary call: expand head and every argument.

A qualified head `alias/name` or `ns/name` names a user macro
when the alias (of the current namespace) or namespace is
registered and its own Var `name` is a bound macro; otherwise it
is an ordinary call. User macros shadow host macros.

### 1.2 User-defined `defmacro`

1. **`Var.macro: bool`** is a field on every Var (`src/vm.zig`).
2. **`defmacro` is an expander-time special form**, not a Tiny
   node, spelled exactly like `defn`: a docstring, an attribute
   map and `^meta` on the name become the Var's metadata, the
   parameters destructure and overload clauses dispatch on the
   argument count, as for `fn`. The expander builds
   `(def name (fn name ...))` (wrapped to set the metadata as
   `defn` does), expands it fully in the enclosing env, and calls
   `ctx.compile_eval.eval` to compile + run it in a fresh sub-VM.
   The resulting Var's `macro` flag is set. The `defmacro` form's
   replacement is `(var name)`, so the REPL prints `#'name`.
   Without a `compile_eval` callback `defmacro` is
   `MalformedMacroCall`.
3. **Invocation**: convert each argument Form → Value
   (`formToValue`), call `VM.evalClosure(var.root, args, &sub_vm)`,
   convert the result Value → Form (`valueToForm`, in the compile
   arena), deinit the sub-VM, recursively re-expand the result.
4. **Fresh sub-VM per call** (never persistent): no handler /
   finally / halted state to save and restore. The macro routine's
   `var_table` holds pointers into the caller's namespace
   (resolved at compile time) and its constant pool holds
   caller-interned literals, so the sub-VM needs no namespace or
   interner of its own.
5. **Persistent allocator**: the compile-eval callback allocates
   the macro fn's storage from a persistent allocator (the VM's
   `runtime_arena`) so the closure outlives the per-form compile
   arena. Both the CLI file runner and the REPL pass one.
6. **Form ↔ Value conversion**. Form → Value: nil, bool, int
   and bigint, real, char, string, symbol, keyword, list, vector,
   map, set, `'x` as `(quote x)`, `@x` as `(deref x)`, `#()` as
   the `fn*` form it stands for and `^m x` as `x` (a symbol cannot
   carry metadata, so a macro sees the form without it). A syntax-quote, unquote or
   unquote-splicing as a macro argument is `MalformedMacroCall`.
   Value → Form: nil, booleans, integers, reals, chars, strings,
   symbols, keywords, lists, vectors, maps and sets; a macro that
   returns any other kind (a function, a Var) is
   `MalformedMacroCall`.
7. **Variadic macros** (`& body`) work; `recur` inside a variadic
   macro body is rejected exactly as at runtime.
8. Macro arguments are **unevaluated Forms-as-Values**; a macro
   body inspects them as data through the core natives (`first`,
   `rest`, `cons`, `list`, `count`, `nth`, `empty?`, ...) and
   builds output with syntax-quote or those natives.
9. **The expander at run time**: `(macroexpand-1 form)` takes a
   form as data and returns one macro step (`expandOnce`: a
   user or host macro at the head, special forms and the `#%`
   primitives excluded; the raw output, nothing inside it
   expanded, no lexical environment) or the form itself;
   `macroexpand` repeats until the head is not a macro.
   `(read-string s)` reads the first form of `s` as data.
   `(eval form)` takes a form as data, macroexpands and compiles
   it in the current namespace with the registry, interner, host
   macro table, loader and a fresh set of declared names, exactly
   as the REPL compiles a line, and runs the routine on the
   calling VM as a nested call (`vm.runRoutine`), returning its
   value: a `def` inside it binds in the current namespace and is
   visible afterwards, a `defmacro` inside it serves a later
   `eval`, `(ns ...)` inside it switches the current namespace,
   a closure it returns is callable afterwards, a dynamic
   binding in force is seen, and `eval` nests. The evaluated
   form has no lexical environment: a `let`-bound name of the
   caller is `UnresolvedSymbol` inside it. The Form tree, the
   routine, its constants and every closure prototype are
   allocated in the VM's runtime arena, so what the form defines
   or returns outlives the call. All three reach the compiler
   through `vm.CompilerHooks` (`compile.RuntimeHooks`, installed
   by the runtime that boots the VM); their values are built on
   the VM heap. Failures throw: `:macro-expansion-failure` and
   `:reader-error` as bare keywords; a form `eval` cannot compile
   throws the map `{:error :compile-error :message "<CompileError
   name>" :form <the form>}` (a value that is not a form, such as
   a list holding a function, is `"UnsupportedForm"`), so
   `(catch :compile-error e ...)` takes it and `ex-message` reads
   the name; a throw inside the evaluated form propagates as an
   ordinary throw. A VM without hooks throws `:no-compiler`.
   Syntax-quote is not data at run time: a quoted form that
   holds one is `UnsupportedFeature` at its own compile and
   `read-string` rejects it, so a macro body given to `eval`
   builds its expansion with `list`, `cons` and quote.

---

## 2. Hand-trace: `(when test body)` expansion

The canonical host macro. Walk through the full pipeline.

### Source

```clojure
(when (< x 10) (def y x) y)
```

### Reader output (Form)

```
Form{ list = [
  Form{ symbol = "when" },
  Form{ list = [Form{symbol="<"}, Form{symbol="x"}, Form{int=10}] },
  Form{ list = [Form{symbol="def"}, Form{symbol="y"}, Form{symbol="x"}] },
  Form{ symbol = "y" },
] }
```

### Macroexpander step

The macroexpander walks the form. Sees `(when ...)` in operator
position. `when` is an unqualified symbol, not a special form,
not lexically bound (this is top-level), not a user macro; found
in `host_macros`. Calls `expandWhen(ctx, call_form, args)` where
`args = [test, body[0], body[1]]`.

`expandWhen` constructs:

```clojure
(if test (do body...) nil)
```

As Forms (via the `make*` helpers, §10b):

```
Form{ list = [
  Form{ symbol = "if" },              // head
  args[0],                            // test, unchanged
  Form{ list = [                      // (do body...)
    Form{ symbol = "do" },
    args[1], args[2],
  ]},
  Form{ nil },                        // else arm
] }
```

The `symbol` forms (`if`, `do`) are synthesized; the test and
body forms are pointers into the input tree (no deep copy — Form
trees are arena-owned and immutable from the expander's POV).

### Recursive expansion

The expander then recursively expands the new form. The new
form's head is `if` — a special form, NOT a macro. Recurse into
the sub-forms:

- `args[0]` = `(< x 10)` — head `<` is not a macro. Sub-forms
  are leaves (symbol `x`, int `10`). No expansion.
- `(do (def y x) y)` — head `do` is a special form. Recurse
  into sub-forms.
  - `(def y x)` — head `def` is a special form. Sub-forms are
    leaves. No expansion.
  - `y` — leaf. No expansion.
- `nil` — leaf. No expansion.

Expansion reaches fixed point. Output Form passed to `lowerForm`.

### `lowerForm` output (Tiny)

```text
Tiny.if_ {
  test_: Tiny.lt { lhs: Tiny.symbol "x", rhs: Tiny.int 10 },
  then:  Tiny.do_ {
    Tiny.def { name: "y", value: Tiny.symbol "x" },
    Tiny.symbol "y",
  },
  else_: Tiny.nil,
}
```

### Bytecode and execution

Standard if-then-else lowering per `COMPILER.md` §5.2. The
macroexpander did the work; the backend sees a vanilla Tiny tree.
The VM reads `x` from its Var, compares to 10, branches, `def`s
`y = x` if true and returns `y`; else returns nil.

---

## 2b. Special-form traversal rules

Each special form has its OWN walking rule — the expander does
NOT do generic "recurse into every sub-form." Wrong traversal
either evaluates names that shouldn't be evaluated (`(def 'x 5)`
attempting to expand the symbol `x`) or fails to expand bodies
that should be expanded.

| Form | Traversal rule |
|---|---|
| `quote` | OPAQUE. Do not recurse into payload. |
| `syntax_quote` (datum) | Transform per §5 rules. |
| `anon_fn` (datum) | Rewrite to `fn*` per §9. |
| `let*` | Do NOT expand binding names. Expand each binding RHS with sequential lexical env (RHS sees prior bindings only). Expand body with all bindings in env. |
| `loop*` | Same as `let*`. |
| `fn*` | Do NOT expand param vector or self-name symbol. Expand body with params + rest + self-name added to env. |
| `letfn*` | Do NOT expand binding names or param vectors. Add all binding names to env FIRST. Expand each fn body with that env + the fn's params. Expand letfn body with the env. |
| `def` | Do NOT expand def name. Expand value if present. Do NOT add def name to lexical env (Vars don't enter the env). |
| `defn` | `(def name (fn name ...))`, so params destructure and overload clauses work as for `fn`. `^meta` on the name (`^:private f` reads as `{:private true}`), a docstring after the name (`:doc`) and an attribute map after that land on the Var: `(defn f "doc" {:k 1} [x] ...)` → `(let* [v# (def f (fn f [x] ...))] (nexis.core/reset-meta! v# {:doc "doc" :k 1 :arglists (quote ([x]))}) v#)`; a definition with none of them leaves the Var's metadata nil. `def` and `defmacro` take `^meta` and a docstring the same way. `(doc f)` prints the `:arglists` and `:doc` of `f`'s Var. |
| `var` | Do NOT expand name. |
| `recur` | Expand each arg (no env change). |
| `try` | Expand the body forms; `catch MATCHER BINDING handler...` passes the matcher and binding symbols through and expands the handler with the binding in env; expand the `finally` body. |
| `set!` | `(set! target v)` → `(nexis.core/var-set (var target) v)` with `v` expanded; `target` must be a symbol, and one bound in the lexical env is refused (`MalformedMacroCall`): a local has no thread binding to rebind. The Var's own checks (`:not-dynamic`, `:no-thread-binding`) happen at run time. |
| `throw`, `do`, `if`, ordinary call, `#%*` constructors | Expand all sub-forms with current env. |
| `defmacro` | §1.2 — spelled like `defn`, evaluated at expansion time; replaced by `(var name)`. |
| `ns` | `(ns NAME)` switches `ctx.registry.current` to the named namespace at expansion time, creating it (parent `nexis.core`) if unregistered; replaced by `nil`. |
| `require` | `(require 'my.ns)` / `(require '[my.ns :as a])`, several specs per call: the file load, registry update and alias entry happen at expansion time through `ctx.load_callback`; replaced by `nil`. Only `:as` is accepted — `:refer` / `:rename` / `:exclude` are `MalformedMacroCall`. |
| Non-symbol head | Treat as ordinary call: expand head + all args. |
| `^meta` | On a vector, map or set literal: `(nexis.core/with-meta coll {meta})`, the map evaluated like any map literal except that a symbol under `:tag` is quoted, so `(meta ^:foo [1])` is `{:foo true}`. On anything else in expression position (a symbol, a call) it is a hint and is dropped. In every binding position (the names and patterns of `let`, `loop`, `let*`, `loop*`, `fn` and `fn*` parameters, a parameter vector itself as a return hint, `:keys` entries, `defrecord` fields, a `catch` binding) the metadata is dropped: `(defn f ^long [^String s] ...)` is `(defn f [s] ...)`. On the name of `def`, `defn` or `defmacro` it becomes the Var's metadata, `^String` as `{:tag String}` with the tag quoted. |

Every sub-form is expanded exactly once, so a user macro runs once
per call site and its side effects happen once.

The macroexpander tracks lexical names in an `ExpandEnv` that
mirrors `compile.LowerEnv` exactly (innermost-first lookup via a
parent walk) so the two stay aligned.

## 3. Lexical shadowing of macros

Macros are shadowable by lexical bindings, exactly like the
compiler's inlineable intrinsics:

```clojure
(let* [when f]
  (when x y))
```

Inside the `let*` body, `when` is lexically bound. The
macroexpander does NOT expand the inner `(when x y)`; it falls
through to ordinary call lowering against the lexically-bound
`when`.

Implementation: the expander walks with its `ExpandEnv`, which
tracks names introduced by `let*`, `fn*`, `letfn*`, `loop*`,
`defn` (body env) and `catch`. Macro lookup is gated on
`!env.contains(name)`.

Special forms (`if`, `do`, `let*`, etc.) remain NON-shadowable.
The expander recognizes special forms BEFORE checking the macro
table.

---

## 4. Auto-gensym for syntax-quote

Per PLAN §14.2 + LispReader.java's `GENSYM_ENV` study in
CLOJURE-REVIEW.md.

**Source syntax**: a symbol suffix `#` inside syntax-quote means
"replace with a unique gensym, consistent within this
syntax-quote scope."

```clojure
`(let [x# 1] x#)
;; expands to
(let [x__123__auto__ 1] x__123__auto__)
;; ^^^^^^^^^^^^^^^^^ same gensym for both `x#`s
```

**Algorithm**: gensym at EXPANSION TIME, not read time (Clojure
does the latter; nexis's reader emits the marker only).

The macroexpander, when entering a `syntax_quote` Form, opens a
fresh `GensymScope` (a map from `name#` to the generated
`name__N__auto__`). Each `name#` referenced within the scope
reuses the mapped value; the first reference allocates a new
entry. Another syntax-quote at the same source position with the
same `x#` gets a DIFFERENT gensym: the scope is per syntax-quote
form.

Gensym name format: `<base>__<counter>__auto__`. The counter is
process-wide, not per context: a generated name may become a Var
that later top-level forms see, so two expansions never share a
name, whichever forms or files they come from. Host macros that need
a fresh name (`and`, `or`, `case`, `condp`, `for`, `defn`
multi-arity, destructuring) call `ctx.gensym(base)` directly.
The `__auto__` suffix is the Clojure convention — it
distinguishes auto-gensym from user-controlled names.

## 4b. SrcSpan / provenance for synthetic forms

- **Reused input subforms** keep their original `origin`.
- **Synthetic forms** created by a macro get the macro CALL
  site's `origin`. So `(when test body)` expanding to
  `(if test (do body) nil)` produces an `if` form whose
  origin points at the original `when` source location.

The `make*` helpers (§10b) take an `origin` parameter to enforce
this rule at the construction site. There is no `generated`
origin kind: an error inside macro output is reported at the
macro call.

---

## 5. Syntax-quote / unquote / unquote-splicing

The reader emits these as canonical Form datums
(`Datum.syntax_quote`, `Datum.unquote`, `Datum.unquote_splicing`).
The expander rewrites them recursively; syntax-quote is built into
the expander, NOT a macro-table entry, and runs whenever an
interner is present.

**Element rules**:

```text
sq(literal)          → literal
sq(symbol)           → (quote <qualified-symbol>)     ; see qualification
sq(symbol-with-#)    → (quote <fresh-gensym>)         ; auto-gensym scope
sq(unquote-X)        → X                              ; passthrough
sq(unquote-splice-X) → ILLEGAL outside a collection
sq(list [...])       → (#%list sq(e1) sq(e2) ...)     ; with splice handling
sq(vector [...])     → (#%vector sq(e1) ...)          ; same
sq(map {...})        → (#%map sq(k1) sq(v1) ...)      ; same
sq(set #{...})       → (#%set sq(e1) ...)             ; same
sq('x)               → (#%list 'quote sq(x))          ; `'a → (quote ns/a)
sq(@x)               → (#%list 'nexis.core/deref sq(x))
sq(#(...))           → sq of the fn* form it stands for
sq(^m x)             → (#%list 'nexis.internal/#%meta sq(x) sq(m))
```

The list a syntax-quoted `^m x` builds turns back into `^m x` when
a macro's result becomes a form, so `` `(def ^:private ~name 1) ``
defines a private Var although a symbol value carries no metadata.

For `unquote-splicing` inside a collection: the element runs
become `(#%concat (#%list e1 ...) X (#%list e2 ...) ...)` where
`X` is the spliced expression, and a vector, map or set is
rebuilt from the resulting list with `nexis.core/vec`,
`(nexis.core/apply nexis.core/hash-map ...)` or
`(nexis.core/apply nexis.core/hash-set ...)`. `coll:concat`
accepts every seqable (nil, list, vector, map as `[k v]`
entries, set), so `~@` splices whatever a seq function returns.
A nested syntax-quote is `MacroExpansionFailure`.

**Qualification** (PLAN §23 #29, Clojure's rule): an unqualified
symbol becomes `ns/name` where `ns` is the namespace whose own
Var it names, searched from the current namespace along its
refer chain (`nexis.core` last), or `nexis.core` when it names
a host macro; a symbol nothing holds qualifies to the current
namespace, so `` `(helper) `` written before `(defn helper ...)`
still meets it. Left bare: auto-gensyms, the special forms
(`quote if do let* loop* recur fn* letfn* def var set! try catch
finally throw defmacro ns require`), `&`, the catch matcher `any`,
`#%` internals and the `%` parameters of `#()`. A qualified
symbol keeps its prefix, an alias resolving to the namespace it
names. Without a named namespace (a bare `Namespace` in tests)
nothing qualifies. A head qualified to `nexis.core` reaches the
host macro table, so `` `(let [x# 1] x#) `` expands through
`nexis.core/let` exactly as `let` does; a qualified symbol
naming the current namespace resolves like a bare one, including
forward references the file declares.

The consequence a macro author meets first: a binding name
written bare inside syntax-quote, `` `(let [x ~a] x) ``, becomes
`user/x`, which cannot be bound. Write `x#` (fresh per
expansion) or `~'x` (deliberate capture), as in Clojure.

**Shadowing safety**: syntax-quote output and host-macro output
must not be capturable by user lexical or Var bindings. If a user
writes `(let* [list 99] `(~x))`, the emitted list construction
must not resolve to the user's `list`. Therefore syntax-quote
emits the internal special forms `#%list` / `#%concat` /
`#%vector` / `#%map` / `#%set`, which the compiler recognizes in
its special-form dispatcher and which are never user-shadowable
(`COMPILER.md` §4.3); the rebuild calls are qualified
`nexis.core/...` symbols for the same reason.

A host macro follows the same rule: every core function its
output calls is emitted as the qualified symbol `nexis.core/name`
through `coreSym` (§10b), never bare. `let` destructures through
`nexis.core/nth`, `nexis.core/next` and `nexis.core/get`; `fn`
overload dispatch counts and tests through `nexis.core/count`,
`nexis.core/=`, `nexis.core/<` and `nexis.core/not` and takes a
clause's rest through `nexis.core/rest`; `case` compares with
`nexis.core/=`; `for` walks with `nexis.core/seq`,
`nexis.core/first`, `nexis.core/next` and `nexis.core/conj`;
`defrecord` builds with `nexis.core/assoc` and tests with
`nexis.core/=`; `case` and `condp` report through
`nexis.core/str`; `@x` is `nexis.core/deref`. So
`(let [nth (fn [& _] :captured)] (let [[a b] [1 2]] [a b]))` is
`[1 2]` and `(defn nth ...)` in the user's namespace changes
nothing about destructuring. A qualified `nexis.core/+` or
`nexis.core/<` is still the inlined intrinsic (`COMPILER.md`
§4.3), so the qualification costs overload dispatch nothing.
Only heads that are special forms or host macros (`let`, `let*`,
`fn`, `fn*`, `loop*`, `if`, `and`, `or`, `recur`, `throw`,
`quote`, `var`, `defn`, `catch`) stay bare, because the compiler
and the macro table recognize them regardless of bindings (§3).

---

## 6. Fixed-point loop termination

```zig
pub const MAX_EXPANSION_DEPTH: u32 = 256; // matches Clojure
```

The depth counts the expansions in a row at one position: a macro
call whose expansion is again a macro call, and so on. The
sub-forms of an expansion start again at 0, so nesting in the
source (300 nested `let`s) never counts. Past the limit the
expander raises `ExpandError.ExpansionDepthExceeded`, which the
compiler reports as `CompileError.MacroDepthExceeded`. This catches
infinite macro loops:

```clojure
(defmacro broken [x] `(broken ~x))
(broken 1)                            ; MacroDepthExceeded
```

Nesting is bounded by the native stack guard (`src/stack.zig`,
`VM.md` §13.1) instead: every recursion of the expander over a form
(the walk, syntax-quote, `#()` scanning, destructuring, and the
Form ↔ Value conversions of macro arguments and results) checks it,
and a form nested past the stack's budget is
`ExpansionDepthExceeded` too, never a fault.

---

## 7. Quoting + macroexpansion ordering

`(quote x)` is **opaque** to the macroexpander. The expander does
NOT walk into quoted sub-forms:

```clojure
(quote (when x y))
```

does NOT expand `when`. The quote produces the literal Form
`(when x y)` as a list value at runtime (`COMPILER.md` §5.1
lowers quoted compound collections through the `#%` constructors).

---

## 8. CompileError vs ExpandError

The `ExpandError` set maps onto `CompileError`:

```zig
pub const ExpandError = error{
    ExpansionDepthExceeded,     // → CompileError.MacroDepthExceeded
    MalformedMacroCall,         // → CompileError.MacroExpansionFailure
    MacroReturnedNull,          // → CompileError.MacroExpansionFailure
    RequiredFileFailed,         // → CompileError.RequiredFileFailed
    ControlTransferred,         // → CompileError.ControlTransferred
    OutOfMemory,                // → CompileError.OutOfMemory
};
```

`RequiredFileFailed` and `ControlTransferred` are not expansion
errors: they are what the loader returns when a `require` ran a
file whose form failed (with no handler in force, or with the
running program's handler taking its throw), passed through under
their own names so that `eval` and the CLI report a runtime
failure as one (COMPILER.md §7, TOOLING.md §1). A file that could
not be found, read or compiled is a malformed `require`.

`MacroDepthExceeded` is distinct because infinite expansion is a
common enough failure mode to warrant its own test category. Every
other expansion error buckets into `MacroExpansionFailure`.
(`MacroReturnedNull` is never raised.)

Every expansion error but out-of-memory also records
`ExpandContext.failure`: the span of the innermost form that failed
and a message naming the problem, for the caller to report.

| Failure | Span | Message |
|---|---|---|
| A macro call's user macro throws | the call | `macro m threw <message>`: an `ex-info` or error map's `:message`, a string, `:keyword` |
| … fails in the VM | the call | `macro m failed: KindMismatch` |
| … gets the wrong number of arguments | the call | `macro m takes 1 argument, got 0` |
| … returns a non-form | the call | `a macro returned a function, which is not a form` |
| An argument a macro cannot take | the argument | `a syntax-quote is not data a macro can take` |
| A binding form's vector | the vector | `let: the binding vector needs an even number of forms` |
| A pattern that cannot bind | the pattern | `cannot bind an integer` |
| Too many expansions in a row (§6) | the form | `macro expansion did not finish after 256 expansions in a row` |
| Nesting past the stack guard (§6) | the innermost list | `form nested too deeply` |
| Any other malformed list | the list | `malformed (when ...)` |

This means the lowering errors `MalformedForm` / `ExpectedSymbol`
/ `ExpectedVector` are NOT raised from inside macro expansion. A
macro call with the wrong shape (e.g., `(when)` with no test)
raises `MacroExpansionFailure`, not `MalformedForm`. The
distinction: `MalformedForm` is about SPECIAL-FORM shape
mismatches that the lowerer catches; `MacroExpansionFailure` is
about MACRO-CALL contract violations that the macro fn catches.
An integer literal outside the fixnum range inside a macro
argument is also `MacroExpansionFailure` (over the whole call
form), because `formToValue` rejects it.

---

## 9. `#(...)` anonymous functions

The reader emits `#(body...)` as `Datum.anon_fn`; the expander
rewrites it:

```
#(+ % %2)     → (fn* [%1 %2] (+ %1 %2))
#(+ %1 %2)    → same
#(inc %)      → (fn* [%1] (inc %1))
#(apply f %&) → (fn* [& %&] (apply f %&))
```

1. Scan the body recursively for placeholder symbols: `%`
   records positional 1, `%N` records positional N (N ≥ 1),
   `%&` marks the rest parameter as used. Every sub-form is
   scanned (lists, vectors, maps, sets, `@x`, `^meta` and the
   unquotes of a syntax-quote) except a quoted one.
2. Param count = max positional N found (0 if none).
3. Generate params `[%1 %2 ... %N]` plus `[& %&]` if rest.
4. Rewrite `%` occurrences in the body to `%1`.
5. Build `(fn* params body...)`.
6. Nested `#()` is rejected (Clojure compatibility); the reader
   already refuses it.

---

## 10. Host macro table

`defaultMacros(allocator)` installs, and the CLI's `nexis run` /
`nexis repl` use:

| Macro | Expands to |
|---|---|
| `let` | `let*` with destructuring: a vector pattern binds each element by `nth`, `& r` to `next` of the source past the elements before it (so `(let [[a & r] [1]] r)` is nil, as `nthnext` gives in Clojure) and `:as` to the source; a map pattern binds `{a :k}`, `:keys` / `:strs` / `:syms` vectors (an entry's own namespace or a `:p/keys` group namespace qualifies the key; a keyword entry in `:keys` is the key), `:or` defaults for an absent key and `:as`; patterns nest; plain symbols pass through. |
| `fn` | `fn*` with destructured params: a pattern param is replaced by a gensym and the body wrapped in a `(let [pattern gensym ...] ...)` that itself destructures; a map pattern after `&` takes keyword arguments (the rest seq becomes the map `nexis.internal/#%kwargs` builds from alternating keys and values or one trailing map). Overload clauses `(fn name? ([x] ...) ([x y] ...) ([x & r] ...))` lower to one variadic `fn*` that binds the argument count and tests the fixed arities in source order, then the variadic clause, then throws `:arity-mismatch`; a clause's rest is `rest` of the packed argument list past its fixed params, so an empty rest is `()` for every `fn`, single-clause or overloaded (`VM.md` §6 packs the empty list); at most one variadic clause, no fixed arity below it or repeated (Clojure's rules). Each clause binds its params from the argument list through `loop`, so `recur` in a clause's tail re-enters that clause with the clause's own arity (a variadic clause's rest param receives the one seq passed), a pattern param destructures again on every iteration, a `recur` count that differs from the clause's param count is `RecurArityMismatch`, and a `loop` nested in the clause owns the `recur`s in its own body. A named `fn` may call itself. |
| `defn` | `(def name (fn name ...))`, so params destructure and overload clauses work as for `fn`. `^meta` on the name (`^:private f` reads as `{:private true}`), a docstring after the name (`:doc`) and an attribute map after that land on the Var: `(defn f "doc" {:k 1} [x] ...)` → `(let* [v# (def f (fn f [x] ...))] (nexis.core/reset-meta! v# {:doc "doc" :k 1 :arglists (quote ([x]))}) v#)`; a definition with none of them leaves the Var's metadata nil. `def` and `defmacro` take `^meta` and a docstring the same way. `(doc f)` prints the `:arglists` and `:doc` of `f`'s Var. |
| `loop` | `loop*`; each pattern is bound to a gensym and destructured again on every iteration, so `recur` rebinds the gensyms. |
| `when` | `(if test (do body...) nil)` |
| `when-not` | `(if test nil (do body...))` |
| `and` | `(and)` → `true`; `(and x)` → `x`; `(and x y)` → `(let* [g x] (if g y g))`; `(and x y z)` → `(let* [g x] (if g (and y z) g))`. Returns the first falsy value or the last value. |
| `or` | `(or)` → `nil`; `(or x)` → `x`; `(or x y)` → `(let* [g x] (if g g y))`; `(or x y z)` → `(let* [g x] (if g g (or y z)))`. Returns the first truthy value or the last value. Both `and` and `or` gensym so the first operand is evaluated once. |
| `cond` | `(cond t1 e1 t2 e2 ...)` → nested `if`. Odd arg count is `MacroExpansionFailure`. No `:else` special case — a keyword test is truthy, so `:else` works by truthiness. |
| `case` | `(case expr k1 v1 k2 v2 ... default?)` → `(let* [g expr] (if (= g 'k1) v1 (if (= g 'k2) v2 ... terminal)))`. Every key is a constant and is never evaluated: a symbol key is that symbol, a vector or map key is that literal, and a list key `(k1 k2)` groups alternatives. The terminal is the trailing odd form when present, otherwise `(throw {:error :no-matching-clause :message "No matching clause: <expr>" :value expr})`. Keys are compared with `=`, not hash-dispatched. |
| `condp` | `pred` and `expr` each evaluated once; clauses become `(if (p c_i e) v_i ...)` with the same default policy as `case`; no match throws the same `:no-matching-clause` map. No `:>>` syntax. |
| `try` | `(try body* (catch M b h*)* (finally f*)?)` → the primitive `(try body* (catch any g <chain>) (finally f*)?)`, where the chain tries the clauses in order, `(if (nexis.internal/#%catch-matches? g M) (let* [b g] h*) ...)`, an `any` matcher needing no test, and ends in `(throw g)` so a value no clause takes unwinds through the `finally` to the enclosing `try`. A matcher is `any`, a keyword `:tag`, which takes a thrown value equal to `:tag`, a map whose `:error` entry is `:tag` (the shape of Nextomic's error maps and of the `case` no-match map), or an `ex-info` map (`{:message m :data d}`, `:cause` when given) whose data's `:error` is `:tag`, or, so code written for Clojure runs, a class-name symbol (`Exception`, `Throwable`, `clojure.lang.ExceptionInfo`, any symbol) or `:default`, which take every value as `any` does (nexis has no classes); anything else is `MacroExpansionFailure`. No clause at all is a finally-only `try`; neither catch nor finally makes the form `(do body*)`. |
| `for` | Eager: one loop per binding pair (`(loop* [s# (seq src) acc# outer] (if s# (let [pat (first s#)] ... (recur (next s#) (conj acc# body))) acc#))`), each pair followed by any number of `:let [b]`, `:when t` and `:while t` in any order; a pattern destructures through `let`. `:when` skips the element, `:while` ends the loop it modifies (outer loops carry on), and both see the pattern and earlier `:let` names. The result is always a vector; no laziness. |
| `->` | `(-> x)` → `x`; `(-> x f)` → `(f x)`; `(-> x (f a b))` → `(f x a b)`; steps chain left to right. A bare-symbol step is `(f)`; any other non-list step is `MacroExpansionFailure`. |
| `->>` | Same, inserting the threaded value as the LAST argument. |
| `defrecord` | Registers the record type and defines `T`, `->T`, `map->T` and one impl per `(method [params] body)` clause under the protocol named by the preceding bare symbol (`docs/PROTOCOLS.md` §4). The Vars it defines besides `T` are visible to `DeclaredNames`, so a form may refer to `->T` before the `defrecord`. |
| `defprotocol` | `(do (def IFoo (nexis.internal/#%register-protocol "<ns>/IFoo" [:bar ...])) (def bar (nexis.internal/#%protocol-fn IFoo :bar)) ...)`; method signatures beyond the name are ignored (`docs/PROTOCOLS.md` §4.1). |
| `extend-type`, `extend-protocol` | Install impls in the protocol registry (`docs/PROTOCOLS.md` §4.2–4.3). |

`unless` is not defined. `&form` / `&env` are not injected into
macro calls.

`src/stdlib/core.nx` and `src/stdlib/nextomic.nx`, embedded at
build time, define further macros in nexis itself through
`defmacro`: `when-let`, `if-let`, `if-not`, `dotimes`, `doseq`,
`while`, `letfn`, `declare`, `cond->`, `cond->>`, `some->`,
`some->>`, `as->`, `with-tx`, `with-read-tx`, `with-snapshot`,
`binding`, `with-conn`. `doseq` takes the same modifiers as
`for` and runs the body for effect, yielding nil. `binding` expands to
`(do (push-thread-bindings (hash-map (var a) va ...)) (try (do body...)
(finally (pop-thread-bindings))))` and `set!` to `(var-set (var a) v)`
(`docs/VM.md` §6.5).

## 10b. Form construction helpers

```zig
pub fn makeList(ctx, items: []*Form, origin: SrcSpan) ExpandError!*Form;
pub fn makeVector(ctx, items: []*Form, origin: SrcSpan) ExpandError!*Form;
pub fn makeSymbol(ctx, name: []const u8, origin: SrcSpan) ExpandError!*Form;
pub fn makeNil(ctx, origin: SrcSpan) ExpandError!*Form;
pub fn makeBool(ctx, value: bool, origin: SrcSpan) ExpandError!*Form;
```

Every helper takes `origin` per §4b. Host macros build all of
their output through them. `makeQualifiedSymbol(ctx, ns, name,
origin)` builds `ns/name`, and `coreSym(ctx, name, origin)` is
`nexis.core/name`: the form of every core function a host macro's
output calls (§5).

---

## 11. What this does NOT change

- The Tiny IR: macroexpand produces Forms, not Tiny.
- The compile backend: the same `compileTinyWithNamespace`
  consumes the (already-expanded) Form via `lowerForm`.
- The VM: no opcodes exist for macroexpansion; `#%list` /
  `#%concat` / `#%vector` / `#%map` / `#%set` lower to the
  `coll:*` opcodes the compiler already emits for quoted compound
  literals.
- The compiler's `CompileError` variants: they still apply to
  forms post-expansion. Macroexpand errors bubble up as
  `MacroDepthExceeded` / `MacroExpansionFailure`.
