# `&form` and `&env` for nexis: design

**Base:** main `c5f800a` (v0.2.0).
**Line references** are to that commit. The revamp-3 cleanup (PRs 36–45) has since moved and trimmed the code, so find each site by name.


**Closes:** TODO.md #11; PLAN §24 #13. **Amends:** PLAN §23 #34 and the §28.4 macroexpander row.

**References:**
- Clojure 1.12.0, `core.clj`:
  - `defmacro` (lines 454-491): `add-implicit-args` puts `&form &env` in front of every arity;
  - `sigs` (234): drops them from `:arglists`.
- Clojure 1.12.0, `Compiler.java`:
  - `macroexpand1` (7509): calls the Var with `(cons form (cons LOCAL_ENV.get() (next form)))`, and on an `ArityException` hides the two extra parameters;
  - `LOCAL_ENV` (199) has root `null`. `registerLocal` (7256) assocs `sym -> LocalBinding`. `load` and `eval` bind it to `null` (8142, 8282).
- Clojure 1.12.0, `LispReader.ListReader` (1239-1256): only a list read through a `LineNumberingPushbackReader` gets `{:line :column}`, and an existing `:line` in its metadata wins. `RT.readString` uses a plain `PushbackReader`, so `read-string` lists get no position.
- nexis:
  - `src/expand.zig`: `ExpandContext.lexical`, `Scope`, `findMacro`, `callUserMacro`, `expandDefmacro`, `formToValue`/`valueToForm`, `expandOnce`;
  - `src/compile.zig`: `expandContext`, `RuntimeHooks`, `compileEvalCallback`;
  - `src/vm.zig`: `SourceInfo.lineCol`, `VM.placeOf`/`place_cache`, `Routine.entryFor`, `ArityPhrase`, `execVarStoreVar`;
  - `docs/MACROEXPAND.md` §1-§4b and §10, `docs/FORMS.md` §4, PLAN §23 #34, §24 #13 and §28.

Oracle: bb 1.12 (sci) wherever it matches JVM Clojure. It does not on top-level `&env`: bb gives `{}` and Clojure gives `nil`, per `Compiler.java` above.

---

## 0. Decision summary

- **Calling convention, as in Clojure.**
  - `defmacro` puts the plain parameters `&form` and `&env` in front of every arity's parameter vector, so a macro's function takes `(&form &env & user-args)`.
  - `:arglists` leaves them out.
  - At a call site the arity check and the arity message count the user's arguments alone.
  - Called directly, the function takes all of them: `(#'m '(m 1) nil 1)`.
- **`&form`.**
  - The call as data: a list of the head symbol, as written, followed by the *identical* argument values the macro receives.
  - When the expansion has a source text, the list carries `{:line l :column c}`.
    - Both are 1-based. The column counts code points, exactly as an error report places the call.
    - A call a macro synthesized carries the place of the macro call that built it (MACROEXPAND §4b).
  - It carries nothing else.
    - `^meta` written on a call is a hint and is dropped before any macro sees it, as on every call (§2b).
    - A list *inside* the arguments carries only its own `^meta`, not its place.
- **`&env`.**
  - `nil` when no local is in scope at the call. That covers the top level, a top-level `fn` with no parameters, and `(let [] ...)`, as in Clojure.
  - Otherwise a map from each local's name (an unqualified symbol) to that same symbol.
  - The locals are what `ExpandContext.lexical` already counts so that locals can shadow macros (MACROEXPAND §3). That is every name bound by `let*`, `loop*`, `fn*` params and self-name, `letfn*` or a `catch` binding, so every `let`, `loop`, `fn`, destructuring gensym, record field and `%n` around the call.
  - A value is the symbol, not Clojure's `LocalBinding`. It is truthy and allocation-free, and it is what babashka gives.
- **Run time.**
  - `macroexpand-1`/`macroexpand` pass the form they are given, as data, and a nil `&env`. That holds also when called from inside a macro body.
  - The form has no place (no source), so `(meta &form)` is nil there.
- **Places never come back.**
  - `valueToForm` drops `:line` and `:column` from a returned *list's* metadata, and drops the metadata entirely when nothing else is left.
  - So the idiom `(with-meta out (meta &form))` returns `out`, a plain list at the call's span. It would otherwise become a `with_meta` Form, which `try`'s clause test, `doForms` and `expandOnce` do not see through.
- **Two adjacent bugs fixed first.** Both get worse with the new convention.
  - `def` keeps a Var's macro flag. `(defmacro m ...)` then `(def m (fn ...))` still expands `(m x)` as a macro (nexis prints `true` where bb prints `false`). With hidden parameters, that call would also be an arity error.
  - `expandOnce` does not look through `^meta` on a call, so `(macroexpand-1 (with-meta '(when 1 2) {:a 1}))` returns the form unexpanded.
- **Places are found from the last place found.** `SourceInfo.lineColFrom` scans only the text between two positions, and the VM's existing `place_cache` uses it in both directions. A file's expansions then cost O(file) in total instead of O(position) per call.
- **No new Form datum, value kind, opcode, image format or store format.**
  - The stdlib image regenerates, since every `core.nx`/`test.nx`/... macro gains two parameter slots, and the build makes it.
- **Estimated size:**
  - `src/`: about +120 lines;
  - tests: about +110;
  - docs: about +60 net (TODO and HANDOFF lose lines).
- **Cost per user-macro call:**
  - one list of n+1 cells;
  - one 2-entry map;
  - one incremental place lookup;
  - when locals are in scope, L symbol interns (lookups) and one bulk map build of L entries.

  Against a fresh sub-VM, the conversion of every argument and of the result, this is a few percent. §6 says how to measure it.

---

## 1. What Clojure does, and what nexis takes

| Aspect | Clojure 1.12 | nexis |
|---|---|---|
| Parameters | `defmacro` prepends `&form &env` to each arity | the same |
| `:arglists` | without them (`sigs` elides) | the same (`defnParts` computes it before they are added) |
| Arity error at a call | `ArityException` with `actual - 2` | "macro m takes 1 argument, got 0", counted without them |
| Direct call `(#'m ...)` | needs form and env first | the same |
| `recur` to a macro fn's top | must pass `&form &env` too | the same (it is the fn's own arity) |
| `&form` value | the call seq, identical object, its args identical to the args | a list of the head and the identical argument values |
| `&form` metadata | the reader's `{:line :column}` merged under the call's own `^meta` | `{:line :column}` only; `^meta` on a call is a dropped hint (§2b) |
| `&env` at top level | `nil` | `nil` |
| `&env` with locals | `{sym LocalBinding}` | `{sym sym}` |
| `&env` keys | every registered local: params, fn self-name, `let`/`loop`/`letfn`/`catch` names, destructuring gensyms | the same set (`ExpandContext.lexical`) |
| A list in the arguments | `{:line :column}` when read from a file | only its `^meta` |
| `(meta '(a b))` | `{:line :column}` | nil (quote constants never carry places) |
| `read-string` lists | no position (plain `PushbackReader`) | no position |
| `macroexpand-1` at run time | the form itself; `&env` = `LOCAL_ENV` (nil outside compilation; the compile env if called from inside a macro body) | the form as data; `&env` nil always |

---

## 2. Exact semantics

This is the text for a new `docs/MACROEXPAND.md` §1.3, "`&form` and `&env`". It is the authority the Amendment Log entry points to.

> A user macro's function takes two parameters before the ones its
> `defmacro` names: `&form`, the call, and `&env`, the locals in scope
> at it, as Clojure's does.
>
> - **`defmacro`** puts the plain symbols `&form` and `&env` at the
>   front of every arity's parameter vector, after the `:arglists` are
>   taken, so `(:arglists (meta #'m))` and `(doc m)` show the
>   parameters as written. They are ordinary locals of the macro's
>   function: a body or a nested binding may shadow them, a `recur` to
>   the top of the function passes them, and `(#'m form env args...)`
>   calls the function directly.
> - **At a call** (`callUserMacro`) the argument count is checked
>   against the function's arities with the two added, and an arity
>   error counts the arguments alone ("macro m takes 1 argument, got
>   0"). The function is called with `&form`, `&env` and the
>   arguments.
> - **`&form`** is the list of the head symbol, as written (`m`,
>   `a/m`, `my.ns/m`), and the argument values themselves:
>   `(identical? (second &form) x)` holds for the first parameter `x`.
>   When the form being expanded came from a source text
>   (`ExpandContext.source`), the list carries the metadata
>   `{:line l :column c}`, the 1-based line and column, in code points,
>   of the call's first character, which is where an error report puts
>   the call. A call a macro built carries the span of the macro call
>   that built it (§4b), so its place is that call's. A form `eval`,
>   `load-string` or `macroexpand-1` is given has no source, and its
>   `&form` carries no metadata. `^meta` written on a call is a hint and
>   is dropped (§2b) before the macro runs. The lists inside the
>   arguments carry their own `^meta` (item 6 of §1.2) and no place.
> - **`&env`** is nil when no local is in scope at the call: at the top
>   level, in a body whose binding forms bound nothing. Otherwise it is
>   a map from the name of every local in scope to that name, a
>   symbol: the names `ExpandContext.lexical` counts (§3), which every
>   `let*`, `loop*`, `fn*` (its parameters and its own name),
>   `letfn*` and `catch` around the call binds, and so the binding
>   forms the host macros expand to, destructuring gensyms included.
>   A name bound in a `let`'s later binding is not yet in scope in an
>   earlier one's value. The values are truthy, so `(&env 'x)`,
>   `(get &env 'x)` and `(contains? &env 'x)` each tell whether `x` is
>   a local here, and `(keys &env)` lists them.
> - **At run time**, `macroexpand-1` and `macroexpand` (§1.2 item 9)
>   pass the form as data as `&form` and nil as `&env`, also when
>   called from inside a macro's body.
> - **Host macros** take neither: a `MacroFn` has the call form and
>   `ctx.lexical` already.

These changes go into §1.2:

- **Item 2** gains the sentence "and puts `&form` and `&env` in front of each arity's parameters (§1.3)".
- **Item 3** reads "the argument count, with `&form` and `&env`, is checked against the macro function's arities".
- **Item 6** gains the sentence: "A list's `:line` and `:column` metadata does not become `^meta`: a form's place is its span, so a list returned with `(with-meta out (meta &form))` is `out`, at the call's span, and a list with other metadata keeps the rest."
- **Item 9's** "no lexical environment" becomes "`&env` nil (§1.3)", and it gains the sentence "`^meta` on the form is dropped first, as on any call".

§10's line "`&form` and `&env` are not passed to any macro (PLAN §23 #34)" is deleted.

---

## 3. Decisions and the alternatives rejected

1. **Two leading parameters (chosen)** against a dynamic Var (`*form*`) or reserved slots that a special symbol reads.
   - The parameters are Clojure's convention, exactly.
   - Ported code that calls `(#'m &form &env ...)` or recurs with them works.
   - They need nothing in the VM.
2. **`&env` values: the symbol (chosen).**
   - Rejected:
     - `nil` values break the truthiness idioms `(&env 'x)` and `(if (get &env s) ...)`;
     - `true` works but says nothing;
     - a descriptor map (`{:name x :arg? b}`) allocates per local per call. It also promises fields that portable code cannot read in Clojure, where `LocalBinding` is reached only by Java interop.
   - The symbol is an immediate (no allocation), truthy, and what sci gives.
   - `.cljc` macros that test `(:ns &env)` to detect ClojureScript get nil and take their Clojure branch, which is right.
3. **`&env` from the expander's `lexical` (chosen), not the compiler's locals.**
   - nexis expands the whole top-level form before `lowerForm` runs, so the compiler's `ScopeTable(Lexical)` does not exist when a macro runs.
   - `lexical` already tracks the same binding forms the compiler lowers. It is exactly the set MACROEXPAND §3 uses to let locals shadow macros, so "is a local" means one thing in both places.
   - Interleaving expansion with lowering, as Clojure's analyzer does, would be a rewrite of both stages.
4. **The place on `&form` only (chosen), not on every list in the arguments.**
   - Clojure's reader puts one on every list. Here that would cost a map per list node of every argument, roughly doubling `formToValue` for list-heavy arguments (`deftest` bodies), plus stripping on the way back.
   - nexis places errors by span (`arg_spans`, §4b), so it needs no line metadata on arguments.
   - The idiom in use is `(meta &form)`.
   - Recorded as a deliberate difference in CLOJURE-REVIEW.md.
5. **No `Form` field for line and column** (§28.1 unchanged). It would add 8 bytes to every Form for a fact only macros read. The span plus the source already determine it.
6. **No `:file` key.** Clojure's reader does not add one, and nexis has no `*file*`.
7. **`^meta` on the call is not merged into `&form`.**
   - nexis drops `^meta` on a call as a hint, before any walker sees it (§2b `^meta` row).
   - Carrying it would add plumbing (`expandFormDepth` → `expandList` → `dispatchList` → `callMacro`) for no nexis use, since there are no type hints.
   - Deliberate difference.
8. **`&env` built per call, not cached per scope.**
   - A cache surviving across macro calls would hold a heap value across a `require` that runs the owning VM and can collect.
   - Invalidating it on every `Scope` change and every `require` costs more code than the build saves.
   - Fallback, only if §6's measurement shows `&env` matters: at `defmacro` time, scan the expanded body for the symbol `&env`. Any read of the local appears there, since `eval` cannot see locals. Keep a bit beside `Var.macro` in the image's flags byte and pass nil when the bit is clear.
9. **Places from the last place (chosen), not `lineCol` from 0 per call.**
   - `lineCol` scans from the start of the text, so a file of N user-macro calls costs O(N × size). For a 100 KB test file of 1500 `is` calls that is about 75 MB scanned.
   - The VM's `place_cache` already remembers the last place for error maps. It scans from there forward or backward, or from 0 when that is shorter.
   - Expansion walks a file roughly in order, and a nested expansion moves at most across the text it converts.
   - A line-start index on `SourceInfo` was rejected: every creator of a `SourceInfo` (CLI, loader, image, tests) would have to build it, or it would need mutation through a `*const`.
10. **`macroexpand-1` from inside a macro body passes nil.** Clojure passes the compile environment, because `LOCAL_ENV` is bound during compilation. Matching that needs the run-time hook to find the active expansion context. Deliberate difference.

---

## 4. Implementation plan

Work in `../nexis-wt-formenv` on branch `formenv`. Each commit passes the full gate. Tests come first in each commit, and the spec is amended in the same commit as the code.

### Commit 1: `vm: def clears a Var's macro flag`

- **Test first** (`test/integration/eval_pipeline.zig`):
  - `(def x 1) (defmacro m [a] a) (def m (fn [a] (symbol? a))) (m x)` → `false` (fails today with `true`);
  - `(defmacro m [a] a) (defn m [a] [a]) (m 1)` → `[1]`.
- **Code** (`src/vm.zig` `execVarStoreVar`): `target.macro = false;`. `defmacro` sets the flag after its `def` has run (`expandDefmacro`), so macros are unaffected.
- **Spec:** `docs/VM.md` §10.7, the `var:store-var` row: "marked bound, its macro flag cleared (a `def` over a macro makes it a function, as Clojure's `def` resets the Var's metadata)". The Var sentence: "`macro` (set by `defmacro`, cleared by `def`)".
- **LOC:** src +1, tests +3, docs +1.

### Commit 2: `vm: a place is found from the last place found`

- **Test first** (inline, `src/vm.zig`): for every pair of positions `a`, `b` in texts with a BOM, multibyte code points, `\r\n`, an empty last line and a position past the end, `lineColFrom(a, lineCol(a), b) == lineCol(b)`. Extend the existing `SourceInfo.lineCol` test.
- **Code:**
  - `pub fn lineColFrom(self, from_pos: u32, from: LineCol, pos: u32) LineCol`:
    - forward: count `\n` in `text[from_pos..pos]`;
    - backward: count `\n` in `text[pos..from_pos]`, then the column from the line start before `pos` (with the BOM rule on line 1);
    - when `pos` is nearer 0 than `from_pos`, it is `lineCol(pos)`.
  - `lineCol` stays as the from-zero case.
  - `VM.placeOf` becomes `pub` and calls `lineColFrom` from `place_cache` when the text is the same.
- **Spec:** `docs/VM.md` §13 (error maps' place keys) gains a sentence: "a place is found from the last place found, so a handler taking errors in a loop, or an expansion walking a file, scans the text once".
- **LOC:** src +25, tests +20.

### Commit 3: `expand: macroexpand-1 sees through ^meta on a call; a returned list keeps no place`

- **Tests first** (`eval_pipeline`):
  - `(defmacro m [x] (list 'do x)) (macroexpand-1 (with-meta '(m 1) {:a 1}))` → `(do 1)` (today `(m 1)`);
  - `(macroexpand-1 (with-meta '(when 1 2) {:a 1}))` → `(if 1 (do 2) nil)`;
  - `(defmacro q [x] (list 'quote (with-meta x {:line 1 :column 2 :k 3}))) (meta (q (a)))` → `{:k 3}`;
  - `(defmacro q2 [x] (list 'quote (with-meta x {:line 1 :column 2}))) (meta (q2 (a)))` → nil;
  - `(defmacro t [& body] (with-meta (cons 'try body) {:line 9 :column 1})) (t (throw :x) (catch any e :caught))` → `:caught`.
- **Code** (`src/expand.zig`):
  - `expandOnce` unwraps a `with_meta` whose target is a list before the list test (+3).
  - In `valueToForm`'s metadata branch, for a `.list` value, filter the meta form's `:line`/`:column` entries (unqualified keywords) and wrap only if entries remain (+10).
- **Spec:** MACROEXPAND §1.2 items 6 and 9 as §2 above says.
- **LOC:** src +13, tests +6.

### Commit 4: `expand: a macro receives &form and &env (PLAN §23 #34)`

**Spec, in the same commit:**
- PLAN:
  - §23 #34 rewritten;
  - §24 #13 removed;
  - §28.4's macroexpander row;
  - the Amendment Log entry (§5 below).
- `docs/MACROEXPAND.md`:
  - new §1.3;
  - §1.2 items 2 and 3;
  - §3 gains the sentence "The same table is `&env` (§1.3).";
  - §10's sentence removed.
- `docs/FORMS.md` §4's macroexpander row: "A macro receives the call (`&form`), the locals in scope (`&env`) and its arguments (PLAN §23 #34)."
- `CLOJURE-REVIEW.md`:
  - the §1 table's Macros row becomes `&form`, `&env` (§23 #34); host macros in Zig plus `core.nx`;
  - the `(macroexpand form)` row reads: Clojure "`&env` the compiler's locals when called while compiling, else nil"; nexis "`&env` nil; `^meta` on the form dropped; subforms never expand";
  - new rows:
    - "`&env`'s values": Clojure `LocalBinding` objects; nexis each local's symbol, so `get`, `contains?`, `keys` and calling the map answer alike;
    - "`(meta x)` of a list a macro receives, `(meta '(a b))`": Clojure `{:line :column}` on every list read from a file; nexis only `&form` carries its place, and argument lists and quoted lists carry only their `^meta`;
    - "`^meta` on a macro call": Clojure in `(meta &form)`; nexis a dropped hint.
- `src/stdlib.zig`, `defmacro`'s doc row: "Defines name as a macro: a function called at compile time with the call form &form, the map &env of the locals in scope, and the unevaluated argument forms, whose result is compiled in place of the call. Spelled as defn."
- `HANDOFF.md`:
  - §6.1 #1 loses "**Macros get no `&form` or `&env`** (§23 #34, §24 #13).";
  - the order-of-work item "The open design question ... `&form`/`&env`" is removed and the rest renumbered;
  - §2's count of record is updated from the gate's summary.
- `TODO.md`: #11 removed.

**Tests first:**
- `test/integration/eval_pipeline.zig`. Sources have no `SourceInfo`, so no places.
  - `(defmacro f [& xs] (list 'quote &form)) (f 1 (+ 2 3))` → `(f 1 (+ 2 3))`.
  - `(defmacro same [x] (identical? x (second &form))) (same (a b))` → `true`.
  - `(defmacro e [] (list 'quote &env)) (e)` → `nil`. Also `((fn [] (e)))` → `nil` and `(let [] (e))` → `nil`.
  - `(defmacro ks [] (list 'quote (sort (keys &env)))) (let [b 1 a 2] (ks))` → `(a b)`.
  - `(defmacro has? [s] (contains? &env s))` with:
    - `[(let [x 1] (has? x)) (has? x)]` → `[true false]`;
    - `((fn f [y] [(has? f) (has? y)]) 0)` → `[true true]`;
    - `(loop [i 0] (has? i))` → `true`;
    - `(letfn [(g [] (has? g))] (g))` → `true`;
    - `(try (throw :t) (catch any z (has? z)))` → `true`;
    - `(let [a (has? a)] a)` → `false`;
    - `(do (let [x 1] x) (has? x))` → `false`;
    - `(when-let [x 1] (has? x))` → `true` (a user macro's output);
    - `(let [[p q] [1 2]] (has? q))` → `true` (destructuring);
    - `(defrecord R [fld] P (m1 [_] (has? fld)))` through a protocol → `true`.
  - `(defmacro lv [s] (list 'quote (get &env s))) (let [x 1] (lv x))` → `x`, and `((get {'x 'x} 'x))`-style calling: `(defmacro cv [s] (list 'quote (&env s))) (let [x 1] (cv x))` → `x`.
  - Arity: `(defmacro m [a] a) (m)` → `MacroExpansionFailure` with detail "macro m takes 1 argument, got 0". Multi-arity "takes 0 or 2 arguments". Variadic "at least 1 argument".
  - `:arglists`: `(defmacro m [x] x) (:arglists (meta #'m))` → `([x])`. `(with-out-str (doc m))` is unchanged (the existing case pins it).
  - Direct call: `(defmacro m [x] (list 'inc x)) (#'m '(m 1) nil 5)` → `(inc 5)`.
  - Destructuring and arities: `(defmacro m ([] 0) ([[a b] & {:keys [c]}] (list '+ a b c))) [(m) (m [1 2] :c 3)]` → `[0 6]`.
  - Shadowing: `(defmacro m [] (let [&form 7] &form)) (m)` → `7`.
  - Run time: `(defmacro m [] (list 'quote [&form &env])) (macroexpand-1 '(m))` → `(quote [(m) nil])`, and `(let [x 1] (macroexpand-1 '(m)))` → the same.
  - `eval`: `(defmacro has? [s] (contains? &env s)) (eval '(let [q 1] (has? q)))` → `true`. `(defmacro w [] (list 'quote (meta &form))) (eval '(w))` → `nil`.
- New pin `test/examples/pins/form-env.nx` and its `.out`. It runs from a file, so places exist.
  - `(defmacro where [] (list 'quote (meta &form)))` called at several lines and columns: indented, after a multibyte string on the same line (the column counts code points), and inside `(when true (where))`, where the arg form keeps its own place.
  - `(defmacro make-where [] '(where))` then `(make-where)`: the built call has the place of `(make-where)`.
  - `(defmacro placed [x] (with-meta (list 'do x) (meta &form)))` returns a value, showing that a place returned in metadata changes nothing.
  - `&env` idioms: `(keys &env)`, `contains?`, a cljc-style `(if (:ns &env) :cljs :clj)` → `:clj`.
  - The header comment states what it pins.
- New CLI golden `test/golden/cli/macro-form.nx` with `.err` (exit 4; a row in `build.zig`'s `cases`): `&form` in an error message, the idiom Clojure's `assert-args` uses:

  ```clojure
  (defmacro pair [& xs]
    (when (not= 2 (count xs))
      (throw (ex-info (str (pr-str &form) " needs two forms, at line " (:line (meta &form))) {})))
    (vec xs))
  (pair 1)
  ```

  The expected stderr is `...:5:1: compile error: macro pair threw (pair 1) needs two forms, at line 5`.

**Code:**
- `src/expand.zig`:
  - `ExpandContext.source: ?*const vm_mod.SourceInfo = null` (+3);
  - `fn placeOf(ctx, pos)`: the owning VM's `placeOf` through `ctx.namespace.registry.vm` when there is one, else `source.lineCol` (+8);
  - in `callUserMacro`:
    - the arity check `entryFor(args.len + 2)`, its message through `arityPhrase` with two hidden;
    - the `&form` list built from `formToValue(items[0])` and the argument values, its metadata `mapFromEntries` of `:line`/`:column` when `ctx.source` is set;
    - `&env` nil, or `champ.mapFromEntries` of `{sym sym}` over `ctx.lexical` entries with a count above 0;
    - `callValue` with `[form, env] ++ args` (+30);
  - `expandDefmacro`: a helper `implicitParams(ctx, tail)` that prepends `&form &env` to the vector (after `stripParams`) or to each clause's vector, applied to `parts.fn_tail` after `defnParts` (+20);
  - `expandOnce`'s doc comment says what `&env` is (0).
- `src/compile.zig` `expandContext`: `.source = opts.source` (+1). `RuntimeHooks.context` leaves it null.
- `src/vm.zig` `ArityPhrase`: `hidden: u8 = 0`, each printed count `n -| hidden` (saturating: a macro Var whose root `alter-var-root` replaced may take fewer) (+5).
- `src/stdlib.zig`: the doc row (0).

**Measure** (§6) before merging.

**LOC:** src +70, tests +80, docs +60 net.

### Not in this work (follow-ons, each its own decision)

- `nexis.test/is` reporting the assertion's line from `(meta &form)` (`FAIL in ns/test at file:12`). It changes every test report and golden.
- `defn`/`defmacro` putting `:line`/`:column` on the Var's metadata. CLOJURE-REVIEW's `(meta #'f)` row records their absence.
- `assert` naming its line.

---

## 5. PLAN text

### §23 #34 (replaces the current item)

> 34. **A macro receives `&form` and `&env` ahead of its arguments**,
>     as Clojure's does: `&form` is the call as data, carrying
>     `{:line l :column c}` when it was read from a source; `&env` is
>     nil when no local is in scope at the call, else a map from each
>     local's name to that name, a symbol. `defmacro` adds the two
>     parameters to every arity and leaves them out of `:arglists`;
>     `macroexpand-1` passes the form it is given and a nil `&env`
>     (`docs/MACROEXPAND.md` §1.3).

### §24 #13

Removed. Closed questions are removed and the numbers stay stable. The list reads #3, #4, #5, #6, #7, #8.

### §28.4, the Macroexpander row's last clause

> passes a macro its call (`&form`), the locals in scope (`&env`) and
> its arguments (§23 #34).

(was: "passes a macro its arguments only (§23 #34).")

### Amendment Log entry (appended after the 2026-10-09 error-map entry)

> - **2026-10-09 — `&form` and `&env` (§23 #34, §28.4; closes §24
>   #13).** A user macro's function takes two parameters before the
>   ones its `defmacro` names, as Clojure's does. `&form` is the call as
>   data: the list of the head symbol as written and the very argument
>   values the macro receives, carrying `{:line l :column c}`, 1-based
>   with the column in code points as an error report places the call,
>   when the call was read from a source, and no metadata when it was
>   built at run time. `&env` is nil when no local is in scope at the
>   call, else a map from each local's name to that name, a symbol: the
>   names the binding forms around the call bind (`let*`, `loop*`,
>   `fn*` and its own name, `letfn*`, a `catch` binding, and so every
>   `let`, `loop`, `fn` and destructuring gensym), the table the
>   expander keeps so that locals shadow macros. The values are not
>   Clojure's `LocalBinding`s, which only Java interop reads; each is
>   truthy, so `(&env 'x)`, `(get &env 'x)` and `(contains? &env 'x)`
>   all tell whether `x` is a local. `defmacro` puts `&form` and `&env`
>   in front of each arity's parameters and leaves them out of
>   `:arglists`; an arity error at a macro call counts the arguments
>   alone; called directly, the function takes the two first.
>   `macroexpand-1` and `macroexpand` pass the form as data and a nil
>   `&env`. A list a macro returns keeps no `:line` or `:column`
>   metadata, since a form's place is its span, so
>   `(with-meta out (meta &form))` returns `out` at the call's place;
>   `^meta` written on a call stays a hint that is dropped, and a list
>   among the arguments carries no place. `def` clears a Var's macro
>   flag, as Clojure's `def` resets the Var's metadata, so a function
>   defined over a macro is called as a function. Reason: Clojure macros
>   use `&form` to put the call's line in their errors and to place
>   what they return, and `&env` to tell a local from a Var, and both
>   are cheap here: the call form is in hand, the expander already
>   keeps the lexical names, and a place is found from the last place
>   found. A macro call costs one more list, one small map and, with
>   locals in scope, a map of them. No Form datum, value kind or opcode
>   is added. `docs/MACROEXPAND.md` §1.3 is the authority;
>   `docs/FORMS.md` §4, `docs/VM.md` §10.7 and §13, the `defmacro`
>   doc row and `CLOJURE-REVIEW.md` carry it.

PLAN's §1 summary and §5 need no change. The §28.1 bullet "a macro sees `x` without it (a symbol carries no metadata)" stays true, since it is about symbols.

---

## 6. Cost and how to measure it

**Per user-macro call, added:**
- `&form`: n+1 cons cells (`list.fromSlice` over values already built), and when there is a source, one `mapFromEntries` of 2 entries plus one place lookup.
- The place lookup scans the text between the last place found and this one.
  - Over a file that is O(size) in total: the loader's top-level forms run in order, and an expansion moves only within the text it converted.
  - A backward move longer than the position itself rescans from 0, which is bounded by the same total.
- `&env`:
  - nothing when no local is in scope;
  - otherwise one pass over `lexical` (its capacity grows with the distinct names the top-level form has bound), L `internSymbolValue` lookups and one `mapFromEntries` of L entries.
- Two more argument slots, and `entryFor(n + 2)`.

**Already paid per call, unchanged:**
- `VM.init` of a sub-VM (a slot stack, a frame, an arena);
- `formToValue` of every argument tree;
- `callValue`;
- `asLists`;
- `valueToForm` of the result and its re-expansion.

The added work is expected to be a few percent of a call.

**Measurement** (optimized, before commit 1 and after commit 4, on the same host):
1. Generate `scratch/macros.nx`: 2000 top-level `(defn fK [a b] (when-let [x a] (if-not b (doseq [y x] (is (= y y))) (with-open [r x] r))))`, with `(require '[nexis.test :refer [is]])` first. That gives about 10 000 user-macro calls (`when-let`, `if-not`, `doseq`, `is`, `with-open`), most with 3 to 6 locals in scope.
2. `zig build install -Doptimize=fast --prefix scratch/fast` at each commit. Time `scratch/fast/bin/nexis disasm scratch/macros.nx > /dev/null`, which compiles every form and runs nothing, best of 10.
3. Budget: at most +10%. If `&env` is the bulk of an overrun, take §3 item 8's fallback (the per-macro `&env` bit) in a further commit with its own test.
4. A file of 20 000 lines and few macro calls must not slow down. This checks the place lookup, which must never rescan per call.

**Gate effects:**
- **Runtime hot paths** (`docs/PERF.md`): none touched. `execVarStoreVar` gains one store, on `def` only.
- **Image:** every stdlib macro routine has two more parameter slots. The image comparison test (`src/image.zig`, boot from image against boot from sources) covers it, and the gensym counter is unaffected because the implicit parameters are not gensyms.
- **`-Dgc-stress`:** expansion never collects. The `&form` list and the `&env` map live on the owning VM's heap, as the arguments do, while a sub-VM that never collects runs the macro. No rooting is added.

---

## 7. Files touched

| File | Commit | Change |
|---|---|---|
| `src/vm.zig` | 1, 2, 4 | `execVarStoreVar` clears `macro`; `SourceInfo.lineColFrom`, `placeOf` pub and incremental; `ArityPhrase.hidden`; inline tests |
| `src/expand.zig` | 3, 4 | `expandOnce` through `^meta`; `valueToForm` drops list places; `ExpandContext.source`, `placeOf`; `callUserMacro` builds `&form`/`&env`; `expandDefmacro` adds the parameters |
| `src/compile.zig` | 4 | `expandContext` passes `opts.source` |
| `src/stdlib.zig` | 4 | `defmacro`'s doc row |
| `test/integration/eval_pipeline.zig` | 1, 3, 4 | the cases above |
| `test/examples/pins/form-env.nx`, `.out` | 4 | new pin |
| `test/golden/cli/macro-form.nx`, `.err`; `build.zig` | 4 | new CLI golden and its `cases` row |
| `PLAN.md` | 4 | §23 #34, §24 #13, §28.4, Amendment Log |
| `docs/MACROEXPAND.md` | 3, 4 | §1.2 items 2, 3, 6, 9; new §1.3; §3; §10 |
| `docs/VM.md` | 1, 2 | §10.7 `store-var` row and Var sentence; §13 place sentence |
| `docs/FORMS.md` | 4 | §4 macroexpander row |
| `CLOJURE-REVIEW.md` | 4 | §1 Macros row; `macroexpand` row; three new rows |
| `HANDOFF.md` | 4 | §6.1 #1 sentence; order-of-work item; §2 count of record |
| `TODO.md` | 4 | #11 removed |

| Area | Estimated net LOC |
|---|---|
| src | +120 (expand.zig +75, vm.zig +40, compile.zig +1) |
| tests | +110 |
| docs | +60 |
| build.zig | +1 |
