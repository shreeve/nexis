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

Cross-examined with GPT-5.4 (Claude-4.6-sonnet peer via `user-ai` MCP) at every major checkpoint. See conversation `nexis-plan-review` turns 5–7 for full dialogue.

---

## Findings summary

Organized by what nexis **takes wholesale**, what it **adapts**, and what it **rejects**.

### 1. Take wholesale

#### 1.1 Compiler-primitive `*` convention + macro bootstrap

Clojure's compiler knows ~20 primitives. User-facing `let`/`fn`/`loop`/`letfn`/`defn` are **macros** in `core.clj` that expand to `let*`/`fn*`/`loop*`/`letfn*`. All destructuring, multi-arity, docstrings, pre/post conditions live in the macros. The compiler stays small and boring.

`core.clj` bootstraps in **two stages**:

1. Define trivial renaming macros: `(defmacro let [&form &env & decl] (cons 'let* decl))`.
2. Later, after destructuring helpers exist, **redefine** `let` with the full destructuring-aware version.

**nexis adoption**: exact. See PLAN.md §6.1 (compiler primitives table + user macros table + two-stage bootstrap note), §21 Phase 3 (stdlib/core.nx with the bootstrap sequence).

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

**nexis adaptation**: per-Var `revision: u32` field. Finer granularity, better for future inline caching. GPT-5.4 confirmed this was already better. PLAN.md §13.3, §23.20.

#### 2.8 Per-thread `threadBound` AtomicBoolean → isolate-global dynamic-binding depth

Clojure puts an `AtomicBoolean threadBound` on every Var as a fast-path flag. Overkill for our single-isolate v1.

**nexis adaptation**: a single isolate-level `dynamic_bindings_depth: u32` counter. If zero, skip the binding-stack walk entirely for any dynamic var lookup. Cleaner.

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

We *planned* RRB and were worried about complexity. Turns out Clojure doesn't ship RRB at all — plain radix trie is what's in production. We can safely demote RRB to v2+ and are no worse off than Clojure itself. PLAN.md §9.2.

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
| BigInt suffix | `42N` | unsupported | Phase 1 auto-promotion |
| BigDecimal suffix | `3.14M` | unsupported | no decimal tower (§23 #10) |
| NaN / ±Inf literal | `##NaN`, `##Inf`, `##-Inf` | unsupported | Phase 3 reader extension |
| `##`-dispatch in general | symbolic values | unsupported | as above |
| **Chars and strings** | | | |
| Char unicode escape | `\u2603` (exactly 4 hex) | `\u{2603}` (variable, braced) | unified escape language (§23 #26) |
| String unicode escape | `"\uHHHH"` | `"\u{HEX}"` | same |
| Octal char | `\o377` | unsupported | `\u{HEX}` subsumes |
| Multi-line strings | allowed | rejected | narrower surface (§7.2) |
| String escape set | `\0 \b \f \n \t \r \\ \" \uHHHH` + octal | `\n \t \r \\ \" \u{HEX}` | narrower surface |
| **Dispatch under `#`** | | | |
| Var-quote | `#'foo` → `(var foo)` | unsupported — write `(var foo)` | minimal reader |
| Namespaced map | `#:ns{:a 1}` | unsupported | deferred; use plain map |
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
| `(= 1 1.0)` | `true` | `false` | PLAN §23 #11 (cross-type `=` deferred to v2 `==`) |
| `(= Double/NaN Double/NaN)` | `false` | `true` (canonical bit pattern) | SEMANTICS §2.2 |
| Integer overflow | auto-promotes to `BigInteger` | Phase 0 rejects; Phase 1 auto-promotes | PLAN §21 Phase 1 gate |
| Syntax-quote expansion | at read time, auto-qualifies + auto-gensyms | reader emits marker only; macroexpander qualifies | PLAN §14.2 (see §2.6 above) |

### 4.4 Explicit omissions (by PLAN §4 non-goals)

These are not "deferred" — they are committed absences for v1. Each has a
frozen rationale in PLAN §4 / §23.

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

GPT-5.4 explicitly flagged these as pending design decisions worth studying before Phase 1:

1. **Printing / readability contract** — which values print in a form that reads back to the same value? Metadata printing, unreadable markers for functions/vars/transients, durable-ref printing.
2. **Collection equality across concrete types** — is `(list 1 2 3) = (vector 1 2 3)`? Clojure says yes for `sequential?` collections; need explicit decision.
3. **Empty list / nil / empty seq subtleties** — nexis §6.5 covers the main cases but there are edge cases (e.g., `(= () nil)`, `(seq [])`) worth nailing down.
4. **Exception / error value design** — stack trace representation, cause chaining, catch matching rules.
5. **Numbers** — deliberately skipped the 4242-line `Numbers.java`. Need to check NaN/−0 handling, overflow promotion rules, equality across fixnum/bignum/f64 boundaries.

These should be pinned down in `docs/SEMANTICS.md` (Phase 0 deliverable) before Phase 1 implementation starts.

---

## PLAN.md changes driven by this review

| Section | Change | Rationale |
|---|---|---|
| §4 non-goals | Changed "seq non-goal" row to a nuanced one, now pointing at §6.6 | seq IS core, just not a straitjacket |
| §6.1 | Rewrote to separate compiler primitives (`*`-suffixed) from user macros | Mirrors Clojure's architecture exactly |
| §6.6 | NEW subsection: seq as core abstraction | Corrects earlier "non-goal" overstatement |
| §8.4 | Rewrote interning for keyword/symbol asymmetry | Correcting the earlier "same intern-id" model |
| §8.7 | NEW subsection: keyword-as-function as v1 feature | Promoted from deferred to language-level commitment |
| §9.2 | Demoted RRB, made plain 32-way the v1 default | Clojure ships plain — so do we |
| §14.1 | Updated macro signature to `(&form, &env, args...)` | Adds scope-aware expansion capability |
| §23 | Added frozen decisions #30–35 | Captures the new commitments |
| §25 | Resolved RRB-complexity risk #11 | Demotion removed the risk |

---

## Conclusion

Reading Clojure's source fundamentally sharpened the PLAN. The biggest wins were:

1. **The `*` primitive + macro layering** architecture that keeps the compiler tiny.
2. **The keyword/symbol asymmetry** — a design insight I would never have guessed from blog posts alone.
3. **The confirmation that plain persistent vector is enough** — removing my single biggest Phase 1 schedule risk.
4. **The macro `&form` / `&env` convention** — adding capability we'd have missed.

None of these were visible from reading Clojure tutorials or my earlier design conversations. They were visible only in the actual source. This review paid for itself many times over before we write a line of nexis code.

**Source citation policy**: all Clojure files are EPL 1.0 licensed. We take architectural ideas, not code. Every implementation is fresh Zig. No direct copy-paste.

---

*Document version: 1.0 — Produced 2026-04-19 after deep source review.*

*Companion to PLAN.md. For the authoritative commitments, see PLAN.md §23.*
