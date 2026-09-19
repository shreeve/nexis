# CLOJURE-REVIEW.md

**Findings from a deep review of Clojure's source code — what nexis takes, adapts, and rejects.**

---

## Scope of review

Direct reading of `misc/clojure/src/jvm/clojure/lang/` (the Java core) and `src/clj/clojure/core.clj` (the standard library bootstrap). Approximately 30,000 lines of code across the files that matter most for a Lisp-runtime design:

| File | Lines | What it taught us |
|---|---|---|
| `Util.java` | 282 | Equality and hashing primitives; `equiv` vs `equals` vs `identical?`; boost-style `hashCombine` |
| `Murmur3.java` | 151 | Clojure's hash function; ordered vs unordered collection hashing |
| `Symbol.java` | 141 | Symbols are *not* interned; metadata-bearing via `withMeta` |
| `Keyword.java` | 267 | Keywords *are* weakly-interned globally; implement `IFn` for map lookup |
| `PersistentArrayMap.java` | 562 | Small-map optimization up to 16 entries; keyword fast path via `==` |
| `PersistentHashMap.java` | 1364 | Classic Bagwell HAMT (not CHAMP); ArrayNode/BitmapIndexedNode/HashCollisionNode |
| `PersistentVector.java` | 1054 | Plain 32-way radix trie with tail buffer; no RRB |
| `ATransientMap.java` | 97 | `ensureEditable` ownership checks on every op |
| `Namespace.java` | 277 | Simple structure; polymorphic mappings (Vars + Classes); CAS updates |
| `Var.java` | 746 | ThreadLocal dynamic binding stack; synchronized root mutation; global `rev` counter |
| `RT.java` | 2414 (key sections) | `instanceof`-based dispatch; `seq` is central |
| `LispReader.java` | 1702 (focus on syntax-quote) | Read-time syntax-quote expansion via dynamic `GENSYM_ENV` and `ARG_ENV` |
| `Compiler.java` | 9681 (special-forms + bootstrap) | Tiny primitive set; `*` convention; two-stage macro bootstrap |
| `core.clj` | 8233 (first 200 lines) | Bootstrap pattern: trivial macros first, redefine later |

Cross-examined with a second model at every major checkpoint.

---

## Findings summary

Organized by what nexis **takes wholesale**, what it **adapts**, and what it **rejects**.

### 1. Take wholesale

#### 1.1 Compiler-primitive `*` convention + macro bootstrap

Clojure's compiler knows ~20 primitives. User-facing `let`/`fn`/`loop`/`letfn`/`defn` are **macros** in `core.clj` that expand to `let*`/`fn*`/`loop*`/`letfn*`. All destructuring, multi-arity, docstrings, pre/post conditions live in the macros. The compiler stays small and boring.

`core.clj` bootstraps in **two stages**:

1. Define trivial renaming macros: `(defmacro let [&form &env & decl] (cons 'let* decl))`.
2. Later, after destructuring helpers exist, **redefine** `let` with the full destructuring-aware version.

**nexis adoption**: exact. See PLAN.md §6.1 (compiler primitives table + user macros table + two-stage bootstrap note), §21 Phase 3 (`src/stdlib/core.nx` with the bootstrap sequence).

#### 1.2 Transient ownership via editable-check

`ATransientMap.ensureEditable()` runs on every op; `persistent()` clears the owner ref, invalidating future calls. Transient auto-promotes when it grows (ArrayMap → HashMap at 16 entries).

**nexis adoption**: same shape, isolate-local token instead of `Thread` identity. See PLAN.md §9.4.

#### 1.3 `seq` as the central abstraction

`core.clj` line 139 defines `seq` as one of the first functions. Every persistent collection has `.seq()`. `RT.first`/`RT.next`/`RT.rest`/`RT.cons`/`RT.count` (via `countFrom`) all funnel through it.

**nexis adoption**: promoted to §6.6 of PLAN.md as a positive commitment (rewriting the earlier "seq as non-goal" stance).

#### 1.4 Keyword-as-function

`Keyword` implements `IFn` directly: `invoke(obj) = RT.get(obj, this)`. This is the language, not an optimization.

**nexis adoption**: §8.7 of PLAN.md, language-level commitment in v1. Arity 1 and 2 only.

#### 1.5 Unbound-as-IFn-sentinel

Clojure's `Var.Unbound` is a callable sentinel that throws `"Attempting to call unbound fn"` when invoked. Not nil, not null — a real callable value.

**nexis adoption**: direct. See PLAN.md §13.3.

#### 1.6 Metadata semantics

Metadata never affects equality or hash. `with-meta` returns a new value; the meta is on a side slot of the heap header. `(meta x)` reads it.

**nexis adoption**: exactly. PLAN.md §8.5.

#### 1.7 Hash-domain separation across kinds

Clojure offsets keyword hashes from same-named symbol hashes by `0x9e3779b9` (golden ratio constant) to prevent HAMT collision when both appear as keys.

**nexis adoption**: same pattern, exact constant to be chosen once xxHash3 is wired up. See PLAN.md §8.4.

---

### 2. Adapt (take the idea, improve the implementation)

#### 2.1 Symbol / keyword asymmetry — but with a smarter symbol representation

Clojure makes every symbol a heap object. That's fine on JVM; wasteful in nexis where we control representation.

**nexis adaptation**:
- **Keywords**: interned immediates, no metadata. (Matches Clojure.)
- **Symbols**: interned identifier in the common case (fast eq/hash); **metadata-bearing symbol** is a heap wrapper allocated *only* when metadata is attached.

This is GPT-5.4's recommendation after reading Clojure's source: "don't cargo-cult the JVM representation; adopt the semantic asymmetry but use a more compact default." PLAN.md §8.4.

#### 2.2 HAMT → CHAMP

Clojure uses classic Bagwell HAMT with single bitmaps and mixed-entry arrays (each slot is either `{key, val}` or `{null, child-node}`). CHAMP (Steindorfer & Vinju, OOPSLA 2015) uses separate data/node bitmaps for measurably better iteration, equality checks, and cache locality.

**nexis adaptation**: target CHAMP. Fall back to classic HAMT only if CHAMP implementation threatens schedule. PLAN.md §9.1.

#### 2.3 Murmur3 → xxHash3

Clojure uses Murmur3 (2008-era). xxHash3 is faster and better-distributed by modern benchmarks. The structural hashing pattern (ordered vs unordered collection hashing, `mixCollHash`) is identical either way.

**nexis adaptation**: xxHash3-64 with Clojure's `(hash = 31 * hash + hasheq(x))` ordered combine and `hash += hasheq(x)` unordered combine. PLAN.md §9.1.

#### 2.4 Two-hash worlds → one language hash

Clojure has `hashCode()` (Java compat) and `hasheq()` (Clojure value hash). The dual exists because of JVM interop obligations.

**nexis adaptation**: one user-visible semantic hash (just called `hash`). Internal implementation may cache, use pointer hash, or other tricks, but users see one function. GPT-5.4 flagged this explicitly — don't inherit JVM baggage.

#### 2.5 Macro signature `(Form, Env) → Form`

Clojure macros receive `&form` (invocation form) and `&env` (lexical environment map of `symbol → LocalBinding`) as invisible first args. Our PLAN originally said `Form → Form` — too weak.

**nexis adaptation**: commit to `(Form, Env) → Form` in v1, but keep `Env` deliberately shallow. PLAN.md §14.1.

#### 2.6 Read-time syntax-quote → post-parse syntax normalization

Clojure's reader expands `` `form `` recursively at read time using `GENSYM_ENV` / `ARG_ENV` ThreadLocal dynamic Vars. Elegant on JVM but requires a stateful reader.

**nexis adaptation**: the nexus-generated parser is stateless LALR. Emit `(syntax-quote form)` and `(#%anon-fn body)` at parse time; do the Clojure-equivalent expansion as a **post-parse syntax-normalization pass**. Semantically identical; architecturally cleaner. PLAN.md §14.2 and §14 generally.

#### 2.7 Global `rev` → per-Var revision counter

Clojure has a single global `Var.rev` int that increments on any root change. Simple but coarse — invalidates every inline cache even when only one Var changed.

**nexis adaptation**: per-Var `revision: u32` field. Finer granularity, better for future inline caching. PLAN.md §13.3, §23.20.

#### 2.8 Per-thread `threadBound` AtomicBoolean → isolate-global dynamic-binding depth

Clojure puts an `AtomicBoolean threadBound` on every Var as a fast-path flag. Overkill for our single-isolate v1.

**nexis adaptation**: no walk at all. The binding in force lives on the Var (`thread_value` + a `thread_bound` flag); the VM keeps only the save stack `binding` pushes and pops (`docs/VM.md` §6.5). A load is one flag test, a Var never bound costs nothing, and `set!` writes the Var directly. One isolate, one thread, so "thread-local" is process-global and a compile-time sub-VM sees the caller's bindings.

---

### 3. Reject (good for Clojure, wrong for nexis)

#### 3.1 JVM-mandated dual `hashCode` / `hasheq`

Clojure ships two hash functions because of Java interop. We have no such obligation.

#### 3.2 Heap-allocated symbols by default

Clojure allocates every symbol. We don't have to.

#### 3.3 Reader-time syntax-quote expansion via ThreadLocal

Requires stateful reader; we don't need it and can't easily build it on top of nexus.

#### 3.4 Global `Var.rev` counter

Coarse; per-Var is better.

#### 3.5 `AtomicReference<Thread>` transient ownership

Thread identity is meaningless in our single-isolate v1. Use an isolate-local token epoch.

#### 3.6 JVM bytecode + ASM compilation path

Clojure compiles to JVM bytecode via `clojure.asm`. We emit our own 64-bit bytecode to our own VM. Different world entirely.

#### 3.7 Classic HAMT single-bitmap node layout

See §2.2 above — CHAMP is better. Clojure hasn't switched because changing the core of a mature language is huge compat/perf risk; we have no such constraint.

#### 3.8 RRB — but for a different reason than expected

Clojure doesn't ship RRB at all — plain radix trie is what's in production. nexis uses the same plain trie and is no worse off than Clojure itself. PLAN.md §9.2.

#### 3.9 Protocols, multimethods, STM, agents, core.async, reader conditionals, tagged literals

All already rejected in PLAN.md §4 non-goals. Source review didn't change that decision.

---

## 4. Reader construct map: Clojure vs nexis

A compact comparison for Clojure programmers reading nexis source (and vice
versa). This is **design-rationale, not reference** — PLAN §7.2 and
`docs/FORMS.md` hold the authoritative nexis reader contract.

Compared against `misc/clojure/src/jvm/clojure/lang/LispReader.java`
(1702 lines) and the Clojure reader reference documentation. Citations are
per subsection, not per row.

### 4.1 Broadly identical surface

Syntax that reads the same in both systems (subject to §4.2 / §4.3 caveats):

- Collection literals: `(a b c)`, `[1 2 3]`, `{:k v}`, `#{x y}`.
- Quoting family: `'x`, `` `x ``, `~x`, `~@x`.
- Deref: `@r`. Anonymous fn: `#(+ %1 %2)` with positional placeholders `%`, `%N`, `%&`.
- Discard: `#_ x` (including stacked `#_ #_ x y z`).
- Metadata sugar: `^:kw x`, `^{:a 1} x`, `^Type x` (with the one canonical
  `^` spelling — see §4.2).
- Keywords `:foo`, `:ns/foo`; symbols `foo`, `ns/foo`, `+`, `->>`, `set!`, etc.
- Chars `\a`, `\newline`, `\space`, `\tab`, `\return`, `\formfeed`,
  `\backspace` (named set).
- Strings `"..."` with the common escapes (`\n \t \r \\ \"`).
- `;` line comments. `(comment ...)` block-comment macro.
- Commas are whitespace. `nil`, `true`, `false` are immediates.

Symbol character class is the same (alphanumerics + `! * + - _ ? < > = & $ . % /`)
with the same `/`-as-namespace-separator rule (at most one `/`, neither
side empty, `/` alone is the division symbol).

### 4.2 Deliberate reader-level divergences

Places where the reader accepts *something different*. Rationale is short;
the long version lives in PLAN §23 frozen decisions and `docs/FORMS.md` §8.

| Construct | Clojure | nexis | Rationale |
|---|---|---|---|
| **Numeric literals** | | | |
| Radix integer | `2r101`, `16rFF`, `36rZZ` | none — `0x`, `0b`, decimal only | simpler grammar |
| Leading `+` on a number | `+42` → integer `42` | `+42` → symbol | no sign-variant tokenization |
| Ratio | `22/7` → `Ratio` | unsupported | number tower is int+bignum+f64 only (§23 #10) |
| BigInt suffix | `42N` | unsupported; an integer literal of any size reads as an integer (`18446744073709551616` is a bignum) and prints with no suffix | one integer type: fixnum + bignum in canonical form (§23 #10) |
| BigDecimal suffix | `3.14M` | unsupported | no decimal tower (§23 #10) |
| NaN / ±Inf literal | `##NaN`, `##Inf`, `##-Inf` | unsupported | `(/ 1.0 0)` and `(- 0.0 (/ 1.0 0))` produce them; no literal syntax |
| `##`-dispatch in general | symbolic values | unsupported | as above |
| **Chars and strings** | | | |
| Char unicode escape | `\u2603` (exactly 4 hex) | `\u{2603}` (variable, braced) | unified escape language (§23 #26) |
| String unicode escape | `"\uHHHH"` | `"\u{HEX}"` | same |
| Octal char | `\o377` | unsupported | `\u{HEX}` subsumes |
| Multi-line strings | allowed | rejected | narrower surface (§7.2) |
| String escape set | `\0 \b \f \n \t \r \\ \" \uHHHH` + octal | `\n \t \r \\ \" \u{HEX}` | narrower surface |
| **Dispatch under `#`** | | | |
| Var-quote | `#'foo` → `(var foo)` | unsupported — write `(var foo)` | minimal reader |
| Namespaced map | `#:ns{:a 1}` | unsupported | use a plain map |
| Auto-resolved keyword | `::k`, `::ns/k` | unsupported | no current-ns at read time |
| Reader conditional | `#?(:clj ...)`, `#?@(...)` | unsupported | single target (§4) |
| Tagged literal | `#inst "..."`, `#uuid ...`, user-ext | unsupported | v1 non-goal (§4) |
| Regex literal | `#"pattern"` | unsupported | library call (§4) |
| Read-time eval | `#=(form)` (gated by `*read-eval*`) | unsupported | no ambient execution at parse |
| Unreadable marker | `#<...>` always errors at read | unsupported | compat surface only |
| Old-style metadata | `#^{...} x` (still parsed) | unsupported | one canonical `^` spelling |
| `#!` comment | comment to end of line, anywhere | unsupported | no shebang interop |

Complete `#`-dispatch inventory in nexis v1: **`#{}` (set)**, **`#(...)`
(anon-fn)**, **`#_` (discard)**. Nothing else is recognized; any other
byte after `#` is a lexer error.

**Error-reporting contract.** Both readers reject the same set of ill-
formed inputs — duplicate literal keys in maps and sets, odd-count maps,
multi-slash qualified names, nested `#(...)`, bare `~`/`~@` outside
syntax-quote. Clojure surfaces these as `IllegalArgumentException` /
`RuntimeException` with ad-hoc messages (`PersistentArrayMap.java:75`,
`LispReader.java:1360`). nexis surfaces them as stable
kebab-case kinds (`:duplicate-literal-key`, `:map-odd-count`,
`:invalid-symbol`, `:nested-anon-fn`, `:unquote-outside-syntax-quote`)
for tooling pattern-matching. See FORMS.md §3 for the full error table.

### 4.3 Same surface, different semantics

Syntax that parses identically but produces different values / behavior.
These are the semantic traps a Clojure programmer will hit.

| Expression | Clojure | nexis | Pin |
|---|---|---|---|
| `(= 1 1.0)` | `true` | `false`; `(== 1 1.0)` is `true` | PLAN §23 #11; `==` is the cross-type numeric equality (PLAN Amendment Log, number tower) |
| `(= Double/NaN Double/NaN)` | `false` | `true` (canonical bit pattern) | SEMANTICS §2.2 |
| Integer overflow | auto-promotes to `BigInteger` (`+'` and friends; the unprimed `+` throws `ArithmeticException`) | every integer operator promotes: `(+ 140737488355327 1)` is the bignum `140737488355328`, and a result that fits i48 is a fixnum again; no `:arithmetic-overflow` from arithmetic | PLAN §23 #10, Amendment Log (bignum arithmetic and literals); SEMANTICS §2.2; BIGNUM.md §9 |
| `number?` / `integer?` on a bignum | `true` | `true`; `even?`, `odd?`, `zero?`, `pos?`, `neg?`, `compare`, `max`, `min` and `hash` are exact over bignums | `vm.isNumber` / `vm.isInteger` |
| `(/ big 2)` inexact | `Ratio` | f64 (`(/ (* 4294967296 4294967296) 3)` → `6.148914691236517E18`); exact quotients stay integers | §23 #10 has no rationals |
| `(long x)`, `(double x)` | `long` throws on a BigInt beyond 64 bits; `(long 3.9)` → `3` | `long` never rejects a size (one integer type); `(long 3.9)` → `3`, `(long 1e30)` is a bignum, NaN/±Inf → `:invalid-argument`; `double` widens a bignum to its nearest f64. `int`, `bigint`, `biginteger`, `short`, `byte`, `float` do not exist | SEMANTICS §2.2 |
| `(iterate f x)`, `(repeat x)`, `(repeatedly f)`, `(range)` | infinite lazy seqs | sequences are eager, so each takes an explicit count: `(iterate f x n)`, `(repeat n x)`, `(repeatedly n f)`; `(range)` is an arity error. `(take n (iterate f x))` ported from Clojure fails at the `iterate` arity | PLAN §4 (no lazy seqs) |
| `(empty record)` | throws `UnsupportedOperationException` | `{}`: a record is a map to every collection function | SEMANTICS §4 |
| Syntax-quote expansion | at read time, auto-qualifies + auto-gensyms | reader emits marker only; the macroexpander qualifies by the same rule (a Var's namespace, else the current one; special forms, `&`, `any` and `#()` parameters stay bare) and auto-gensyms; `~@` splices any seqable into lists, vectors, maps and sets | PLAN §14.2, MACROEXPAND.md §5 |
| `(try ... (catch Exception e ...))` | catches by class hierarchy | `(catch any e ...)` takes every thrown value; `(catch :tag e ...)` takes the value `:tag`, a map whose `:error` is `:tag`, or an `ex-info` map whose data's `:error` is `:tag`; clauses are tried in order and the rest is rethrown through `finally` | MACROEXPAND.md §10, PLAN §6.4 |
| `(ex-info msg data)` | an `ExceptionInfo` object | the map `{:message msg :data data}` (`:cause` with a third arg); `ex-message`/`ex-data` read those entries of any map and are nil elsewhere | MACROEXPAND.md §10 |
| `(reduced x)` | an opaque `Reduced` box | a record of the type `nexis.core/Reduced` with one field `:val`; `reduced?` tests the type, `@` unwraps; honoured by `reduce`, `reductions`, `reduce-kv` and folds built on them; `into` has no transducer arity, so nothing to honour there | core.nx |
| `(macroexpand-1 form)`, `(macroexpand form)` | expands with `&env` of the call site | one step of a user or host macro at the head, at top level with no lexical environment; `macroexpand` repeats until the head is not a macro; subforms are never expanded | MACROEXPAND.md §1.2 item 9 |
| `(read-string s)` | reads with the full reader, `*read-eval*` | the first form as data; syntax-quote, unquote and `^meta` are not data and throw `:reader-error`, as does a string that does not parse | MACROEXPAND.md §1.2 item 9 |
| `(eval form)` | compiles and runs the form in the namespace `*ns*` names, on the calling thread; `(ns ...)` inside it rebinds `*ns*` for the rest of the enclosing `binding`; a compile error is a `CompilerException` | compiles and runs the form in the current namespace on the calling VM, as the REPL compiles a line; there is no `*ns*` Var to bind: `(ns ...)` inside `eval` switches the current namespace for everything after, exactly as at the REPL; a `def` binds in it, a `defmacro` serves a later `eval`, a returned closure stays callable, a dynamic binding in force is seen, `eval` nests; a compile error is the catchable map `{:error :compile-error :message "<CompileError name>" :form form}`; a throw inside is an ordinary throw; no lexical environment; syntax-quote is not data at run time | MACROEXPAND.md §1.2 item 9, COMPILER.md §7 |
| `(long-array xs)`, `(double-array xs)`, `aget`/`aset`/`areduce`/`amap` | mutable primitive Java arrays; no typed vector in Clojure | `(i64-vector xs)` / `(f64-vector xs)`: immutable unboxed typed vectors, read by `nth`/`get`/`count` and every seq function, never `=` to a vector, no `conj`/`assoc`; kernels in `nexis.simd` (`sum`, `dot`, `scale`, `map`) | docs/TYPED_VECTOR.md |
| `(meta f)` on a function, `(with-meta 'sym m)` | metadata on fns and symbols | nil / `:no-metadata-on-immediate`; collections and Vars carry metadata, `defn`'s Var carries `:doc`, `:arglists` and its attribute map once given any of them, else nil | SEMANTICS.md §7 |
| `(case x ...)` with no matching clause | throws `IllegalArgumentException` "No matching clause: x" | throws the map `{:error :no-matching-clause :message "No matching clause: x" :value x}`; `condp` throws the same. Keys are constants exactly as in Clojure: `(1 2)` groups, `sym` is the symbol | MACROEXPAND.md §10 |

### 4.4 Explicit omissions (by PLAN §4 non-goals)

These are committed absences for v1. Each has a frozen rationale in
PLAN §4 / §23; atoms and protocols left this list by PLAN Amendment Log
entries.

- **Protocols** (`defprotocol`, `extend-type`) — pick a built-in
  polymorphism story first.
- **Multimethods** (`defmulti`, `defmethod`) — overkill before type
  universe is stable.
- **Software transactional memory** (`ref`, `dosync`, `alter`) — emdb
  transactions are the language tx story (§15).
- **Atoms** (in-memory CAS) — durable refs fill the identity role.
- **Agents** (`send`, `send-off`) — JVM-era artifact; isolates later.
- **`core.async`** — huge scheduling sink.
- **Full hygienic macros** — auto-gensym + syntax-quote qualification only.
- **Lazy sequences everywhere** — eager by default; explicit streams in v2.
- **Regex / reader conditionals / tagged literals** — see §4.2.
- **Rationals / BigDecimal** — see §4.2.
- **Multi-target compilation** — Zig-native only.

When a Clojure programmer asks "where's X?", the answer for everything
in this list is *"on purpose — see PLAN §4."*

---

## Things I didn't study deeply but should track

Design decisions the review flagged as worth studying; each is pinned in `docs/SEMANTICS.md`:

1. **Printing / readability contract** — which values print in a form that reads back to the same value? Metadata printing, unreadable markers for functions/vars/transients, durable-ref printing.
2. **Collection equality across concrete types** — is `(list 1 2 3) = (vector 1 2 3)`? Clojure says yes for `sequential?` collections; need explicit decision.
3. **Empty list / nil / empty seq subtleties** — nexis §6.5 covers the main cases but there are edge cases (e.g., `(= () nil)`, `(seq [])`) worth nailing down.
4. **Exception / error value design** — stack trace representation, cause chaining, catch matching rules.
5. **Numbers** — `Numbers.java` (4242 lines) was read only for its BigInt `quotient`/`remainder` and `ops` contagion rules; NaN/−0 handling, promotion and equality across fixnum/bignum/f64 are pinned in `docs/SEMANTICS.md` §2.2 and `docs/BIGNUM.md` §9.

`docs/SEMANTICS.md` pins all five.

---

## Where PLAN.md carries these conclusions

| Section | What it states | Rationale |
|---|---|---|
| §4 non-goals | seq is core, not a straitjacket; the row points at §6.6 | seq IS core, just not a straitjacket |
| §6.1 | Compiler primitives (`*`-suffixed) are separate from user macros | Mirrors Clojure's architecture exactly |
| §6.6 | seq as the core abstraction | The sequence library is written against it |
| §8.4 | Interning is asymmetric between keywords and symbols | Keywords are identities; symbols are names |
| §8.7 | Keywords are functions | A language-level commitment |
| §9.2 | The vector is a plain 32-way trie; RRB is absent | Clojure ships plain — so do we |
| §14.1 | Updated macro signature to `(&form, &env, args...)` | Adds scope-aware expansion capability |
| §23 | Added frozen decisions #30–35 | Captures the new commitments |
| §25 | Resolved RRB-complexity risk #11 | Demotion removed the risk |

---

## Conclusion

Reading Clojure's source fundamentally sharpened the PLAN. The biggest wins were:

1. **The `*` primitive + macro layering** architecture that keeps the compiler tiny.
2. **The keyword/symbol asymmetry** — a design insight I would never have guessed from blog posts alone.
3. **The confirmation that plain persistent vector is enough** — removing the single biggest runtime-core schedule risk.
4. **The macro `&form` / `&env` convention** — adding capability we'd have missed.

None of these are visible from Clojure tutorials. They are visible only in the actual source.

**Source citation policy**: all Clojure files are EPL 1.0 licensed. We take architectural ideas, not code. Every implementation is fresh Zig. No direct copy-paste.

---

*Companion to PLAN.md. For the authoritative commitments, see PLAN.md §23.*
