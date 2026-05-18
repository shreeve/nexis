# MACROEXPAND.md — Phase 2 step #8 design spec

**Status**: Draft. Pre-implementation spec for the macroexpander
(step #8 per [`COMPILER.md`](COMPILER.md) §10). Authoritative for
expansion semantics, the execution model, and the bootstrap
sequence. Derivative from [`PLAN.md`](../PLAN.md) §6.1 (primitive
core), §14.1-14.2 (macros + syntax-quote), [`CLOJURE-REVIEW.md`](../CLOJURE-REVIEW.md)
§1.1 (Compiler-primitive `*` convention + two-stage bootstrap),
peer-AI conversation `nexis-phase-1` turns 51, 53, 55.

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
whose `lowerForm` shape is what the rest of the pipeline already
understands. **It produces no new Form datums** — the output is
a subset of the input's `Datum` taxonomy.

The macroexpander is also the **first place quoted-compound
output appears**. `(when test body...)` expands to `(if test (do body...) nil)`,
constructed as a Form list with synthesized `if`/`do`/`nil`
sub-forms. This is why step E1 (`Tiny.literal: Value` + Interner)
is a hard prerequisite — without it, quoted symbols in macro
output have no compile target.

---

## 1. Execution model: stage-1 host-Zig macros only

**Decision** (peer-AI turn 55 §K): for Phase 2 step #8, macros
are **host-Zig callback functions**. There is no user-defined
`defmacro` in step #8.

```zig
pub const ExpandContext = struct {
    allocator: std.mem.Allocator,
    interner: *intern_mod.Interner,
    /// Monotonic counter for auto-gensym. Per peer-AI turn 56:
    /// LIVES ON THE CONTEXT, not the VM. Macroexpand runs
    /// before VM execution (and possibly without a VM at all,
    /// e.g. compiler tooling that only expands).
    gensym_next: u64 = 0,
    host_macros: *const HostMacroTable,
};

pub const MacroFn = *const fn (
    ctx: *ExpandContext,
    call_form: *const reader.Form,    // the (when x y) form being expanded
    args: []const *reader.Form,        // the args after the head: [x, y]
) ExpandError!*reader.Form;       // returns the rewritten form
```

The context bundle (peer-AI turn 56 §1.2) is mandatory — `or`
expansion needs gensym, syntax-quote needs gensym, future macros
may need shared state. Passing a flat parameter list locked us
into a brittle API.

A **host macro table** maps symbol names to MacroFn:

```zig
pub const HostMacroTable = std.StringHashMapUnmanaged(MacroFn);
```

The macroexpander consults this table during traversal:

```text
for each list form (head ...):
  if head is unqualified symbol AND host_macros.get(name) != null:
    AND name not lexically shadowed:
      call the macro fn → new form
      recursively expand the new form
  else:
    recurse into sub-forms
```

### Why host-Zig and not user-defined `defmacro` in v1

User-defined `defmacro` requires running arbitrary nexis code
**at compile time**. That implies:

1. A compile-time VM (or sharing the runtime VM with care).
2. Macro Vars distinguished from regular Vars (`:macro true`
   metadata, per Clojure).
3. Compile-time namespace resolution that finds macros.
4. Fixed-point expansion that handles macro fns calling other
   macro fns.

All four are tractable, but each is a separate design surface.
Per CLOJURE-REVIEW.md §1.1 the bootstrap sequence is:

> 1. Stage 1 — trivial renaming macros land first
>    (`(defmacro let [& decl] (cons 'let* decl))`).
> 2. Stage 2 — once destructuring helpers exist, redefine
>    user-facing `let` with the full destructuring-aware
>    version via `core.nx`.

Both stages REQUIRE user-defined `defmacro` to exist. But stage 1
is so simple that we can implement EACH of those trivial macros
as a Zig function for v1 step #8, and ship `defmacro` as a Phase 3
deliverable when we're ready to round-trip a compile-time VM.

**The set of host macros for step #8** (peer-AI turn 55 §8c):

| Macro | Expands to | Notes |
|---|---|---|
| `when` | `(if test (do body...) nil)` | Stage 1 trivial |
| `when-not` | `(if test nil (do body...))` | Stage 1 trivial |
| `unless` | `(if test nil (do body...))` | Alias for when-not |
| `and` | nested `(if a (if b ... false) false)` | Variadic — short-circuit |
| `or` | nested `(if a a (if b b ...))` | Variadic — short-circuit, gensym-aware |
| `cond` | nested `(if c1 e1 (if c2 e2 ...))` | Variadic, pairs |
| `->` (thread-first) | `(f (g (h x)))` → `(h x)` wrapped | Threading macro |
| `->>` (thread-last) | Same but last-arg | Threading macro |
| `defn` multi-arity | `(defn f ([x] e1) ([x y] e2))` → fn* with dispatch | Sugar; depends on multi-arity support |

The `defn` multi-arity sugar is borderline — it depends on
either a runtime multi-arity dispatch machinery (PLAN §6.1
sketches this) OR a macro that lowers to single-arity fn* +
explicit arity check. **For step #8 we punt multi-arity to
Phase 3.** Single-arity `defn` already works via the existing
`Tiny.defn` lowering.

### User-defined `defmacro` — SHIPPED (Phase 3.2)

Per peer-AI turn 66 architectural pin, user `defmacro` works
via these mechanics:

1. **`Var.macro: bool`** field on every Var (`src/vm.zig`).
2. **`defmacro` is an expander-time special form**, not a Tiny
   IR node. The expander recognizes `(defmacro name [params] body)`,
   pre-expands the body in an env that includes the self-name +
   params, builds the synthetic form
   `(def name (fn* name [params] body))`, and calls the
   `CompileEvalContext.eval` callback to compile + run it in a
   fresh sub-VM. The resulting Var pointer is mutated to set
   `macro = true`. The defmacro expansion result is `(var name)`
   so the REPL prints `#'name`.
3. **User-macro invocation** (`expandList`): on a list whose
   head is a symbol, after lexical-shadowing check, look up in
   `ctx.namespace`. If the Var has `.macro = true`, convert
   each arg Form → Value (`formToValue`), call
   `vm_mod.VM.evalClosure(var.root, args, &sub_vm)`, convert
   the result back to Form (`valueToForm` in `ctx.allocator`),
   recursively re-expand.
4. **Fresh sub-VM per call** (not persistent), per peer-AI turn
   66 §D1 — avoids handler/finally/halted state save/restore.
   The macro routine's `var_table` already holds pointers into
   the caller's namespace (resolved at compile time), and the
   constant pool already holds caller-interned literals, so the
   sub-VM doesn't need its own namespace/interner.
5. **Persistent allocator threading**: the compile-eval callback
   uses a separate `persistent_allocator` (typically
   `vm.runtime_arena.allocator()`) for the macro fn's storage so
   the Closure outlives the per-form compile arena. REPL passes
   this; without it, defmacros only work inside a single arena
   lifetime (e.g., one `nexis run FILE.nx` invocation).
6. **Lookup order** (`expandList`): lexical env → user macros
   (`Var.macro`) → host macros → ordinary call. User macros
   shadow host macros (override allowed).
7. **Form↔Value conversion supports**: nil, bool, int, symbol,
   keyword, list, vector, map, set, quote (normalized to a
   2-list). `MalformedMacroCall` for syntax-quote/unquote/
   splicing/anon-fn/with-meta/deref/real/char/string as macro
   args (deferred to a later commit).
8. **Variadic macros** (`& body`) work end-to-end. Variadic
   recur in macros: same restriction as runtime (rejected for
   v1).
9. **Host fns for macro authoring** (`cons`/`first`/`rest`/
   etc.) are deferred to Phase 3.3 — v1 macros are syntax-quote-
   only, which covers `unless`/`when-not`/`cond`-likes/
   threading variants.

---

## 2. Hand-trace: `(when test body)` expansion

The canonical stage-1 macro. Walk through the full pipeline.

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
position. `when` is unqualified symbol. Looks up in
`host_macros` — found. Looks up in lowering-env-style lexical
context — NOT shadowed (this is top-level). Calls
`expandWhen(allocator, interner, call_form, args)` where
`args = [test, body[0], body[1]]`.

`expandWhen` constructs:

```clojure
(if test (do body...) nil)
```

As Forms (using a small `FormBuilder` helper):

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

- `args[0]` = `(< x 10)` — head `<` is an intrinsic, NOT a
  macro. Sub-forms are leaves (symbol `x`, int `10`). No
  expansion.
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

### `compileTinyWithNamespace` output (bytecode)

Standard if-then-else lowering per the existing backend. No
new opcodes; no new compile machinery. The macroexpander did
all the heavy lifting; the backend sees a vanilla Tiny tree.

### VM execution

Reads `x` from namespace (Var lookup), compares to 10, conditional
jump, def'd `y = x` if true, returns `y`; else returns nil.

---

## 2b. Special-form traversal rules
(peer-AI turn 56 §2.A: "exactly where macroexpanders go wrong")

Each special form has its OWN walking rule — the expander must
NOT do generic "recurse into every sub-form." Wrong traversal
either evaluates names that shouldn't be evaluated (`(def 'x 5)`
attempting to expand the symbol `x`) or fails to expand bodies
that should be expanded.

| Form | Traversal rule |
|---|---|
| `quote` | OPAQUE. Do not recurse into payload. |
| `syntax_quote` | #8a: OPAQUE/UNSUPPORTED. #8c: transform per §5 rules. |
| `let*` | Do NOT expand binding names. Expand each binding RHS with sequential lexical env (RHS sees prior bindings only). Expand body with all bindings in env. |
| `loop*` | Same as `let*`. |
| `fn*` | Do NOT expand param vector or self-name symbol. Expand body with params + rest + self-name added to env. |
| `letfn*` | Do NOT expand binding names or param vectors. Add all binding names to env FIRST. Expand each fn body with that env + the fn's params. Expand letfn body with the env. |
| `def` | Do NOT expand def name. Expand value if present. Do NOT add def name to lexical env (Vars don't enter LowerEnv). |
| `defn` | Do NOT expand name or param vector. Expand body with params + rest + self-name added to env. |
| `var` | Do NOT expand name. (var has only the name; no other sub-forms.) |
| `recur` | Expand each arg (no env change). |
| `do`, `if`, ordinary call, intrinsics | Expand all sub-forms with current env. |
| Non-symbol head | Treat as ordinary call: expand head + all args. |

The macroexpander reuses `ExpandEnv` paralleling `LowerEnv`
(same shape) for the lexical-name tracking.

## 3. Lexical shadowing of macros

Per peer-AI turn 53 §"Critical trap" (reused for #8): macros
are shadowable by lexical bindings, exactly like inlineable
intrinsics. The macroexpander reuses the `LowerEnv` pattern:

```clojure
(let* [when f]
  (when x y))
```

Inside the `let*` body, `when` is lexically bound. The
macroexpander does NOT expand the inner `(when x y)`; it falls
through to ordinary call lowering against the lexically-bound
`when`.

Implementation: the expander walks with its own `ExpandEnv`
(parallel to LowerEnv) that tracks names introduced by `let*`,
`fn*`, `letfn*`, `loop*`, `defn` (body env). Macro lookup is
gated on `!env.contains(name)`.

Special forms (`if`, `do`, `let*`, etc.) remain NON-shadowable.
The expander recognizes special forms BEFORE checking the macro
table.

---

## 4. Auto-gensym for syntax-quote (step #8b)

Per PLAN §14.2 + LispReader.java's `GENSYM_ENV` study from
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

**v1 algorithm**: gensym at EXPANSION TIME, not READ TIME
(Clojure does the latter for historical reasons; peer-AI turn 7
recommended the simpler model).

The macroexpander, when entering a `syntax_quote` Form, opens a
fresh `GensymScope` (a `StringHashMap([]const u8)` mapping
`name#` to the generated `name__N__auto__`). Each `name#`
referenced within the scope reuses the mapped value; first
reference allocates a new entry.

Gensym name format: `<base>__<counter>__auto__`. Counter lives
on `ExpandContext.gensym_next` (peer-AI turn 56 §1.4 +
§5: NOT the VM — macroexpand runs before VM execution and may
run without a VM at all). The context is reused across all
top-level forms in one compilation unit so gensyms remain
unique. `__auto__` suffix is the Clojure convention —
distinguishes auto-gensym from user-controlled `(gensym ...)`.

## 4b. SrcSpan / provenance for synthetic forms
(peer-AI turn 56 §2.C: add this rule NOW even though full
error-reporting hardening is step #10)

- **Reused input subforms** keep their original `origin`.
- **Synthetic forms** created by a macro get the macro CALL
  site's `origin`. So `(when test body)` expanding to
  `(if test (do body) nil)` produces an `if` form whose
  origin points at the original `when` source location.
- Future (step #10 + beyond): introduce a `generated`
  origin kind that carries both the macro-call span AND
  the macro-output span, so error messages can say "in
  macro expansion of WHEN at line 5".

FormBuilder helpers (see §10b) take an `origin` parameter
to enforce this rule at the construction site.

---

## 5. Syntax-quote / unquote / unquote-splicing (step #8b)

The reader already emits these as canonical Form datums
(`Datum.syntax_quote`, `Datum.unquote`, `Datum.unquote_splicing`).
The expander rewrites them recursively.

**Expansion rules** (PLAN §14.2):

```text
sq(literal)          → literal
sq(symbol)           → (quote <interned-symbol>)
sq(symbol-with-#)    → (quote <fresh-gensym>)         ; auto-gensym scope
sq(unquote-X)        → X                              ; passthrough
sq(unquote-splice-X) → ILLEGAL outside list context
sq(list [...])       → (list sq(e1) sq(e2) ...)       ; with splice handling
sq(vector [...])     → (vector sq(e1) ...)            ; same
```

For `unquote-splicing` inside a list: the surrounding `(list ...)`
construction becomes a `(concat (list e1) X (list e2) ...)`
where `X` is the spliced expression.

**This requires runtime `list`, `vector`, `concat` functions.**
For v1 step #8c: ship `list` and `concat` as host-Zig builtins
registered as core Vars. `vector` defer if compound vector
literals aren't needed by stage-1 macros (probably not — when/
cond/and/or all produce list output only).

**Shadowing safety** (peer-AI turn 56 §5.Trap 4): syntax-quote
generated calls to `list` / `concat` MUST NOT be capturable by
user lexical/Var bindings. If a user writes
`(let* [list 99] `(~x))`, we can NOT have the syntax-quote
emission of `(list x)` resolve to the user's `list` binding.
Three options:

1. Emit qualified core symbols (`nexis.core/list`). Cleanest
   long-term; requires multi-ns support which is post-v1.
2. Emit an internal special form (`#%list`, `#%concat`)
   recognized by the compiler. Hides the implementation; ugly.
3. Pre-resolve to native-fn Values at expansion time and emit
   `Tiny.literal`-bearing constructor calls.

For v1 step #8c: option (2) — `#%list` / `#%concat` recognized
in the special-form dispatcher, never user-shadowable.
Post-#8 (when multi-ns lands): migrate to (1) for proper
Clojure semantics.

---

## 6. Fixed-point loop termination

```zig
const MAX_EXPANSION_DEPTH: u32 = 256; // matches Clojure
```

Each recursive expansion of a form increments a depth counter.
If depth exceeds the limit, raise `ExpandError.ExpansionDepthExceeded`.
This catches infinite macro loops:

```clojure
(defmacro broken [x] `(broken ~x))   ; future-Phase-3 user macro
(broken 1)                            ; would infinite-loop without the limit
```

For step #8's host-only macros, none of `when`/`cond`/`and`/etc.
recurse — the depth limit is defensive against future user macros.

---

## 7. Quoting + macroexpansion ordering

`(quote x)` is **opaque** to the macroexpander. The expander does
NOT walk into quoted sub-forms:

```clojure
(quote (when x y))
```

does NOT expand `when`. The quote produces the literal Form
`(when x y)` as a list value at runtime (eventually — requires
quoted-compound-collection support, step #8c+).

For step #8 the expander recognizes `(quote ...)` as a stop-
walking marker. The quoted payload is passed through to
`lowerForm`'s existing quote handling (scalars only for now;
compound quoted lists land when the runtime list-construction
path is wired alongside macros).

---

## 8. CompileError vs ExpandError
(peer-AI turn 56 §1.7 chose Option B — distinct depth error)

The `ExpandError` internal error type is rich; for v1 it
maps to TWO CompileError variants:

```zig
pub const ExpandError = error{
    ExpansionDepthExceeded,     // → CompileError.MacroDepthExceeded
    MacroReturnedNonForm,       // → CompileError.MacroExpansionFailure
    MalformedMacroCall,         // → CompileError.MacroExpansionFailure
    OutOfMemory,                // → CompileError.OutOfMemory
};
```

Distinct `MacroDepthExceeded` because infinite expansion is a
common-enough failure mode (especially as user `defmacro`
arrives in Phase 3) to warrant its own test category.

All OTHER macroexpand errors (malformed macro calls, macro
returning the wrong shape, etc.) bucket into the single
`MacroExpansionFailure` for v1. Step #10 (error reporting
hardening) splits these out with SrcSpans + original variant
preservation.

Note: this DOES mean the existing `MalformedForm` /
`ExpectedSymbol` / `ExpectedVector` errors are NOT raised from
inside macro expansion. A macro call with the wrong shape
(e.g., `(when)` with no test) raises `MacroExpansionFailure`,
not `MalformedForm`. The distinction: `MalformedForm` is
about SPECIAL-FORM shape mismatches that the lowerer catches;
`MacroExpansionFailure` is about MACRO-CALL contract violations
that the host macro fn catches.

---

## 9. New CompileError variants

For step #8a (scaffold):

| Variant | When |
|---|---|
| `MacroExpansionFailure` | Bucketed wrapper for any ExpandError |
| `MacroDepthExceeded` | Specific case (worth distinct so users can recognize infinite loops) |

The existing `MalformedForm` / `ExpectedSymbol` / `ExpectedVector`
errors continue to apply to malformed macro calls; the expander
raises them when it discovers a macro call doesn't match the
expected shape (e.g. `(when)` with no test).

---

## 10b. FormBuilder helpers
(peer-AI turn 56 §2.D — without these, macro code duplicates
allocator+form construction everywhere)

```zig
pub const FormBuilder = struct {
    allocator: std.mem.Allocator,
    interner: *intern_mod.Interner,

    pub fn symbol(self: *FormBuilder, name: []const u8, origin: SrcSpan) !*Form;
    pub fn qualifiedSymbol(self: *FormBuilder, ns: []const u8, name: []const u8, origin: SrcSpan) !*Form;
    pub fn nil_(self: *FormBuilder, origin: SrcSpan) !*Form;
    pub fn bool_(self: *FormBuilder, value: bool, origin: SrcSpan) !*Form;
    pub fn int(self: *FormBuilder, value: i64, origin: SrcSpan) !*Form;
    pub fn list(self: *FormBuilder, items: []const *Form, origin: SrcSpan) !*Form;
    pub fn vector(self: *FormBuilder, items: []const *Form, origin: SrcSpan) !*Form;
    pub fn quote(self: *FormBuilder, payload: *Form, origin: SrcSpan) !*Form;
    /// Step #8c: gensym-mapped symbol for auto-gensym output.
    pub fn gensym(self: *FormBuilder, base: []const u8, ctx: *ExpandContext, origin: SrcSpan) ![]const u8;
};
```

Every helper takes `origin` per §4b. Macro expanders create a
FormBuilder once and use it for all output forms.

## 10. Sub-step breakdown
(peer-AI turn 56 §1.8 swapped #8b ↔ #8c — host macros can use
direct FormBuilder without runtime list/concat. Syntax-quote
needs runtime construction support so it lands separately.)

### #8a: Macroexpand scaffold + no-op traversal + special-form boundaries

- New `src/expand.zig` module.
- `ExpandContext`, `HostMacroTable`, `MacroFn`,
  `ExpandError` types per §1.
- `pub fn expandForm(ctx, env, depth, form) → *Form`.
- Recursive walk per §2b's per-form rules. `quote` and
  `syntax_quote` BOTH opaque in #8a (syntax_quote lands at
  #8c).
- Macro table EMPTY for #8a; the expander becomes a no-op on
  every input form (output = input structurally).
- `ExpandEnv` mirroring `LowerEnv` for lexical-name tracking.
- Depth limit (256) + `MacroDepthExceeded` /
  `MacroExpansionFailure` errors.
- Wire into `compileSourceFull` / `compileFormFull`: optional
  `host_macros: ?*const HostMacroTable` parameter (default
  null = no expansion).
- FormBuilder skeleton (just enough for #8b to use it).
- Tests: scaffolding correctness (every existing source-string
  test still passes through with empty macro table).

### #8b: Host core macros (using direct FormBuilder; NO runtime list/concat needed)

Wire the macro table:

```zig
pub fn defaultMacros(allocator: std.mem.Allocator) !HostMacroTable {
    var table: HostMacroTable = .empty;
    try table.put(allocator, "when", expandWhen);
    try table.put(allocator, "when-not", expandWhenNot);
    try table.put(allocator, "and", expandAnd);
    try table.put(allocator, "or", expandOr);   // uses gensym (see below)
    try table.put(allocator, "cond", expandCond);
    try table.put(allocator, "->", expandThreadFirst);
    try table.put(allocator, "->>", expandThreadLast);
    // Renaming macros per CLOJURE-REVIEW.md §1.1 (peer-AI
    // turn 56 §2.F):
    try table.put(allocator, "let", expandLetRename);   // (let ...) → (let* ...)
    try table.put(allocator, "fn", expandFnRename);     // (fn ...)  → (fn* ...)
    try table.put(allocator, "loop", expandLoopRename); // (loop ...) → (loop* ...)
    return table;
}
```

Macro semantics (peer-AI turn 56 §2.G-J):

- `when`: `(when test body...)` → `(if test (do body...) nil)`
- `when-not`: `(when-not test body...)` → `(if test nil (do body...))`
- `and` — **MUST USE GENSYM** to return the first falsy value
  (Clojure semantics: returns the actual falsy value, NOT
  literal `false`):
  ```clojure
  (and)       => true
  (and x)     => x
  (and x y)   => (let* [g x] (if g y g))
  (and x y z) => (let* [g x] (if g (and y z) g))
  ```
- `or` — **MUST USE GENSYM** to avoid double evaluation:
  ```clojure
  (or)       => nil
  (or x)     => x
  (or x y)   => (let* [g a] (if g g b))    ; g = gensym
  (or x y z) => (let* [g x] (if g g (or y z)))
  ```
- `cond`: `(cond t1 e1 t2 e2 ...)` → nested if. Odd arg
  count = `MacroExpansionFailure`. No `:else` special case
  in v1 (keyword used as truthy test works).
- `->` (thread-first):
  ```clojure
  (-> x)            => x
  (-> x f)          => (f x)
  (-> x (f a b))    => (f x a b)
  (-> x f (g a))    => (g (f x) a)
  ```
- `->>` (thread-last): same but inserts as LAST arg.
- `let` / `fn` / `loop`: trivial rename to `let*` / `fn*` /
  `loop*`. Pure (cons 'let* decl) shape.

Each expander uses FormBuilder. NO runtime list/concat needed
(macros construct output Forms directly via builder).

CLI's `nexis run` uses the default macro table.
`examples/` populates with programs using `when`/`cond`/`->`.

Tests for each macro + the gensym hygiene case
(`(or false 42)` → `42` proves single-evaluation;
`(or (side-effect) (side-effect))` would prove
side-effect-once if we had side effects, which we don't yet).

### #8c: Syntax-quote / unquote / unquote-splicing + native list/concat

The subtle part. Lands separately because it requires runtime
list construction (peer-AI turn 56 §4 + §5):

- Expand `syntax_quote` per §5 rules.
- Auto-gensym across the syntax-quote scope.
- Decide native-fn Value vs internal special-form for
  `list`/`concat` emission (per §5 shadowing-safety): v1
  uses internal `#%list` / `#%concat` special forms — unshadowable
  by user code.
- VM gains `coll:list` / `coll:concat` opcodes (the `coll`
  group is already reserved in vm.zig); OR pre-compiled Tiny
  routines registered as core Vars at VM init. Pick at #8c
  strategy turn.
- Tests: simple syntax-quote round-trip, unquote, splice,
  auto-gensym hygiene, `'foo` and `` `foo `` symmetry.

### #8d (optional, defer to Phase 3): user-defined `defmacro`

Requires compile-time VM eval. Significant scope. Per peer-AI
turn 55: defer unless explicitly planned. Steps #8a-c give us
working macros via host fns; #8d gives users the ability to
write their own. Phase 3 deliverable, after stdlib bootstrap.

---

## 11. What this does NOT change

- The Tiny IR: macroexpand produces Forms, not Tiny.
- The compile backend: same `compileTinyWithNamespace` consumes
  the (already-expanded) Form via `lowerForm`.
- The VM: no new opcodes for macroexpansion; `list` and `concat`
  builtins land as either native-fn Values or pre-compiled
  Routines.
- The compiler's existing CompileError variants: still apply to
  forms post-expansion. Macroexpand errors bubble up as
  `MacroExpansionFailure` for v1.

---

## 12. Amendment log

- **2026-05-17** (initial draft, peer-AI turns 51 + 53 + 55):
  Macroexpander as Form → Form rewriter; host-Zig macros for
  v1 (defer user `defmacro` to Phase 3); reuse the LowerEnv-
  pattern for macro shadowing; #8a-c sub-step plan.
- **2026-05-17** (peer-AI turn 56 review pass — 11 spec edits
  applied BEFORE coding):
  1. MacroFn takes `*ExpandContext`, not flat params.
  2. Gensym counter lives on ExpandContext, not VM.
  3. Reordered #8b ↔ #8c: host macros first (direct
     FormBuilder, no runtime collection ops needed),
     syntax-quote + list/concat second.
  4. Added §2b special-form-traversal table (per-form rules
     instead of generic recursion — this is where macroexpanders
     go wrong).
  5. `quote` AND `syntax_quote` both opaque in #8a; #8c
     implements syntax_quote.
  6. Added §4b SrcSpan/provenance rule: synthetic forms get
     the macro CALL's origin; reused subforms keep theirs.
  7. Error model picked Option B: `MacroDepthExceeded` is
     a distinct CompileError; everything else maps to
     `MacroExpansionFailure`.
  8. Removed multi-arity `defn` from the step-#8 macro
     table (deferred to Phase 3 with `defmacro`).
  9. Added `let`/`fn`/`loop` rename macros per
     CLOJURE-REVIEW.md §1.1.
  10. `or` MUST use gensym to avoid double-evaluation;
      spec'd the exact expansion shape.
  11. Syntax-quote-emitted `list`/`concat` must be
      unshadowable by user bindings — v1 uses internal
      `#%list` / `#%concat` special forms.
