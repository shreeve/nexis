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
    /// Monotonic counter for auto-gensym. Lives on the
    /// context, not the VM: macroexpand runs before VM
    /// execution and may run without a VM at all.
    gensym_next: u64 = 0,
    host_macros: *const HostMacroTable,
    namespace: ?*vm_mod.Namespace = null,          // user-macro lookup
    compile_eval: ?CompileEvalContext = null,      // defmacro evaluation
    registry: ?*vm_mod.NamespaceRegistry = null,   // ns / qualified macros
    load_callback: ?LoadCallback = null,           // (require ...)
};

pub const MacroFn = *const fn (
    ctx: *ExpandContext,
    call_form: *const reader.Form,    // the (when x y) form being expanded
    args: []const *reader.Form,        // the args after the head: [x, y]
) ExpandError!*reader.Form;       // returns the rewritten form

pub const HostMacroTable = std.StringHashMapUnmanaged(MacroFn);
```

The context bundle lives for one compilation unit (one CLI
invocation, one REPL session, one test); reusing it across forms
is how auto-gensym stays monotonic within a unit.

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
   node. The expander recognizes `(defmacro name [params] body)`,
   pre-expands the body in an env that includes the self-name +
   params, builds the synthetic form
   `(def name (fn* name [params] body))` and calls
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
   (must fit the fixnum range), symbol, keyword, list, vector,
   map (flat pairs, even count), set, `quote` (normalized to a
   2-list). Any other datum as a macro argument (real, char,
   string, syntax-quote, unquote, splicing, anon-fn, with-meta,
   deref) is `MalformedMacroCall`. Value → Form: nil, booleans,
   fixnum, float, char, symbol, keyword, list, vector, map, set,
   string; any other kind is `MacroReturnedNull`.
7. **Variadic macros** (`& body`) work; `recur` inside a variadic
   macro body is rejected exactly as at runtime.
8. Macro arguments are **unevaluated Forms-as-Values**; a macro
   body inspects them as data through the core natives (`first`,
   `rest`, `cons`, `list`, `count`, `nth`, `empty?`, ...) and
   builds output with syntax-quote or those natives.

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
| `defn` | Do NOT expand name or param vector. Expand body with params + rest + self-name added to env. |
| `var` | Do NOT expand name. |
| `recur` | Expand each arg (no env change). |
| `try` | Expand the body forms; `catch MATCHER BINDING handler...` passes the matcher and binding symbols through and expands the handler with the binding in env; expand the `finally` body. |
| `throw`, `do`, `if`, ordinary call, `#%*` constructors | Expand all sub-forms with current env. |
| `defmacro` | §1.2 — evaluated at expansion time; replaced by `(var name)`. |
| `ns` | `(ns NAME)` switches `ctx.registry.current` to the named namespace at expansion time, creating it (parent `nexis.core`) if unregistered; replaced by `nil`. |
| `require` | `(require 'my.ns)` / `(require '[my.ns :as a])`, several specs per call: the file load, registry update and alias entry happen at expansion time through `ctx.load_callback`; replaced by `nil`. Only `:as` is accepted — `:refer` / `:rename` / `:exclude` are `MalformedMacroCall`. |
| Non-symbol head | Treat as ordinary call: expand head + all args. |

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
`ExpandContext.gensym_next`, monotonic across the whole
compilation unit, so two separate syntax-quotes never collide
even though their scopes are independent. Host macros that need
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
sq(nil / bool / int / real / char / string / keyword)
                     → the literal itself (self-evaluating)
sq(symbol)           → (quote symbol)
sq(symbol#)          → (quote <gensym from the current scope>)
sq(unquote-X)        → X                     ; expanded and evaluated normally
sq(unquote-splice-X) → ILLEGAL outside list-element position
sq(list [...])       → (#%list sq(e1) sq(e2) ...)
                       or, with splices,
                       (#%concat (#%list ...) X (#%list ...) ...)
sq(vector [...])     → (#%vector sq(e1) ...)  ; same splice handling
sq(map / set / quote / nested syntax-quote / anon-fn /
   with-meta / deref)
                     → MalformedMacroCall
```

**Shadowing safety**: syntax-quote output must not be capturable
by user lexical or Var bindings. If a user writes
`(let* [list 99] `(~x))`, the emitted list construction must not
resolve to the user's `list`. Therefore syntax-quote emits the
internal special forms `#%list` / `#%concat` / `#%vector`, which
the compiler recognizes in its special-form dispatcher and which
are never user-shadowable (`COMPILER.md` §4.3). `#%map` / `#%set`
serve quoted compound map / set literals the same way.

---

## 6. Fixed-point loop termination

```zig
pub const MAX_EXPANSION_DEPTH: u32 = 256; // matches Clojure
```

The depth counter increments on EACH macro expansion (not on
tree-walk recursion), so legitimate deep source is not limited.
If depth exceeds the limit, the expander raises
`ExpandError.ExpansionDepthExceeded`, which the compiler reports
as `CompileError.MacroDepthExceeded`. This catches infinite macro
loops:

```clojure
(defmacro broken [x] `(broken ~x))
(broken 1)                            ; MacroDepthExceeded
```

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
    OutOfMemory,                // → CompileError.OutOfMemory
};
```

`MacroDepthExceeded` is distinct because infinite expansion is a
common enough failure mode to warrant its own test category. Every
other expansion error buckets into `MacroExpansionFailure`.

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
   `%&` marks the rest parameter as used.
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
| `let` | `let*` with destructuring: non-symbol patterns (sequential `[a b c]`, associative `{:keys [...] :or {...} :as name}`, nested, `& rest`) expand to extra `let*` bindings over `nth` / `get` / `rest`; plain symbols pass through. |
| `fn` | `fn*` with destructured params: a pattern param is replaced by a gensym and the body wrapped in a `(let [pattern gensym ...] ...)` that itself destructures. |
| `defn` | `(def name (fn name [params] body...))`, so params destructure. Multi-arity `(defn name ([p1] b1) ([p1 p2] b2))` becomes one variadic `fn` over `[& args]` that `count`s the arguments and dispatches through nested `if`s to a `let*` per arity, throwing `:arity-mismatch` when none matches. At most one variadic overload; its fixed count must exceed every fixed-arity overload's (Clojure's rule). |
| `loop` | `loop*` (rename). |
| `when` | `(if test (do body...) nil)` |
| `when-not` | `(if test nil (do body...))` |
| `and` | `(and)` → `true`; `(and x)` → `x`; `(and x y)` → `(let* [g x] (if g y g))`; `(and x y z)` → `(let* [g x] (if g (and y z) g))`. Returns the first falsy value or the last value. |
| `or` | `(or)` → `nil`; `(or x)` → `x`; `(or x y)` → `(let* [g x] (if g g y))`; `(or x y z)` → `(let* [g x] (if g g (or y z)))`. Returns the first truthy value or the last value. Both `and` and `or` gensym so the first operand is evaluated once. |
| `cond` | `(cond t1 e1 t2 e2 ...)` → nested `if`. Odd arg count is `MacroExpansionFailure`. No `:else` special case — a keyword test is truthy, so `:else` works by truthiness. |
| `case` | `expr` evaluated once via gensym; `(case e k1 v1 k2 v2 ...)` → chained `(if (= g k_i) v_i ...)`; a trailing odd form is the default; with no default and no match it throws `:no-matching-clause`. Keys are compared with `=`, not hash-dispatched. |
| `condp` | `pred` and `expr` each evaluated once; clauses become `(if (p c_i e) v_i ...)` with the same default / `:no-matching-clause` policy as `case`. No `:>>` syntax. |
| `for` | Eager: nested `reduce` calls, one per binding pair, `conj`ing onto a `[]` accumulator; the result is always a vector. Supports multi-binding cartesian products, `:let` (through `let`, so it destructures) and `:when`; several modifiers between bindings, in order. The first segment must be a `sym src` pair. No `:while`, no laziness. |
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
`with-conn`.

## 10b. Form construction helpers

```zig
pub fn makeList(ctx, items: []*Form, origin: SrcSpan) ExpandError!*Form;
pub fn makeVector(ctx, items: []*Form, origin: SrcSpan) ExpandError!*Form;
pub fn makeSymbol(ctx, name: []const u8, origin: SrcSpan) ExpandError!*Form;
pub fn makeNil(ctx, origin: SrcSpan) ExpandError!*Form;
pub fn makeBool(ctx, value: bool, origin: SrcSpan) ExpandError!*Form;
```

Every helper takes `origin` per §4b. Host macros build all of
their output through them.

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
