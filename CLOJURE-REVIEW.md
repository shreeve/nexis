# CLOJURE-REVIEW.md

What nexis takes from Clojure's implementation, what it adapts, what it
rejects, and where a Clojure programmer will find it different. The
reference is Clojure 1.12 (`clojure/clojure`, tag `clojure-1.12.0`):
`src/jvm/clojure/lang/` for the runtime (`Util`, `Murmur3`, `Symbol`,
`Keyword`, `PersistentArrayMap`, `PersistentHashMap`,
`PersistentVector`, `ATransientMap`, `Var`, `RT`, `LispReader`,
`Compiler`) and `src/clj/clojure/core.clj`. When a question turns on
what Clojure does, read that source or run a Clojure 1.12 REPL before
asserting it. Clojure is EPL 1.0: nexis takes ideas, never code.

PLAN §23 holds the frozen decisions this file explains; where the two
differ, PLAN wins.

---

## At a glance

| Aspect | Clojure | nexis |
|---|---|---|
| Host | JVM | native Zig; no host interop |
| Value | heap objects and boxed primitives | 16-byte tagged cell; immediates for nil, booleans, chars, i48 fixnums, f64, keywords, symbols (§23 #1) |
| Maps and sets | array map, then Bagwell HAMT | array map to 8 entries, then CHAMP (§23 #37) |
| Vector | 32-way trie with a tail | the same (§23 #30) |
| Numbers | long, BigInt, Ratio, BigDecimal, double | fixnum + bignum, f64; no ratio or decimal (§23 #10) |
| Sequences | lazy | eager; sequence functions return lists (§23 #14) |
| Identity | Vars, atoms, refs (STM), agents | Vars, atoms, durable refs over emdb; no STM or agents (§23 #5, #6) |
| Polymorphism | protocols, records, multimethods | protocols and records; no multimethods (§23 #8, #9) |
| Transactions | STM `dosync` | emdb read and write transactions, lexically scoped |
| History | none built in | `db/snapshot`; Nextomic `as-of`, `since`, `history` (§23 #22) |
| Macros | `&form`, `&env`, full `core.clj` | arguments only (§23 #34); host macros in Zig plus `core.nx` |
| Concurrency | threads, futures, `core.async` | one isolate, one thread (§23 #5) |

---

## 1. Taken

### 1.1 Compiler primitives and macro layering

Clojure's compiler knows a small set of special forms; `let`, `fn`,
`loop`, `letfn` and `defn` are macros over `let*`, `fn*`, `loop*` and
`letfn*`, and all destructuring, arity dispatch and docstrings live in
the macros. nexis keeps the split (§23 #31). The difference is where
the macros live: `let`, `fn`, `loop`, `defn`, `cond`, `->` and the
other surface forms are host macros written in Zig in the expander,
complete from the start; `core.clj`'s two-stage bootstrap (a trivial
`let`, redefined once destructuring exists) has no counterpart.
`letfn`, `binding`, `case` and the rest of the library macros are in
`src/stdlib/core.nx` (`docs/MACROEXPAND.md`).

### 1.2 Transient ownership

`ATransientMap.ensureEditable` checks ownership on every operation, and
`persistent!` ends it. nexis transients check an owner token on every
operation and freeze on `persistent!` (§3.5). They are shallow: an
operation calls the persistent one underneath and swaps the result in,
so it costs what the persistent operation costs (`docs/TRANSIENT.md`).

### 1.3 `seq` as the iteration abstraction

Every collection has a `seq` view, and `first`, `rest`, `next` and
`count` are written against it (§23 #35). Map lookup, vector indexing
and typed-vector kernels stay direct.

### 1.4 Callable keywords and symbols

`Keyword` implements `IFn` as `get`; so does `Symbol`. In nexis `(:k m)`
and `(:k m d)` are `get`, a symbol in function position looks itself up
the same way, and maps, sets and vectors are callable (§23 #33).

### 1.5 Unbound Vars

A declared, unbound Var holds a sentinel; calling or loading it raises
`:unbound-var`. Clojure's `Var.Unbound` is a callable that throws; the
effect is the same.

### 1.6 Metadata

Metadata never affects `=` or `hash` (§23 #12); `with-meta` returns a
new value with the map in the heap header. Collections and Vars carry
it; records, functions, symbols and keywords do not
(`docs/SEMANTICS.md` §7).

### 1.7 Hash-domain separation

Clojure offsets a keyword's hash from the same-named symbol's by the
golden-ratio constant. nexis generalizes it: every kind's hash is offset
by its kind tag times `0x9E3779B97F4A7C15` (`src/hash.zig`), so values
of different kinds with the same payload do not collide.

---

## 2. Adapted

### 2.1 Symbols are immediates

Clojure allocates every symbol. nexis interns symbols like keywords, so
equality and hashing are integer compares; the price is that a symbol
carries no metadata (§23 #32).

### 2.2 CHAMP instead of HAMT

Separate data and node bitmaps (Steindorfer and Vinju, OOPSLA 2015)
give a canonical layout, faster iteration and cheaper equality.
Clojure keeps the classic HAMT for compatibility; nexis has none to
keep (`docs/CHAMP.md`).

### 2.3 xxHash3 instead of Murmur3

xxHash3-64 for immediates and strings, with Clojure's ordered
(`31 * h + hash(x)`) and unordered (`h + hash(x)`) collection combines.
There is one user-visible hash; Clojure's `hashCode`/`hasheq` pair
exists only for Java.

### 2.4 Syntax-quote after reading

Clojure's reader expands `` ` `` at read time with thread-local gensym
state. nexis's parser is a stateless LALR table, so the reader emits a
`syntax-quote` marker and the macroexpander does the expansion by
Clojure's rules: qualification, auto-gensym, unquote and splicing
(PLAN §28.4, `docs/MACROEXPAND.md`).

### 2.5 Dynamic binding without a thread-local stack

A Var holds the binding in force (`thread_value` and a `thread_bound`
flag); `binding` saves and restores it in a `finally`. A load is one
flag test, and `set!` writes the binding in force, never the root
(`docs/VM.md`).

---

## 3. Rejected

- **3.1** A second, JVM-mandated hash function.
- **3.2** Heap-allocated symbols.
- **3.3** Read-time syntax-quote with reader state.
- **3.4** A global Var revision counter: nothing in nexis caches on
  Var roots, so there is nothing to invalidate.
- **3.5** Thread identity as the transient owner: one thread makes it
  meaningless; nexis uses a per-transient token.
- **3.6** JVM bytecode: nexis compiles to its own 64-bit instructions
  for its own slot VM.
- **3.7** Multimethods, STM, agents, `core.async`, reader conditionals
  and tagged literals (PLAN §4).

---

## 4. Differences a Clojure programmer will meet

`docs/FORMS.md` and PLAN §28 are the reader's contract; the tables below
are the map for someone who knows Clojure.

### 4.1 The same surface

- Collection literals `(a b c)`, `[1 2 3]`, `{:k v}`, `#{x y}`; commas
  are whitespace.
- `'x`, `` `x ``, `~x`, `~@x`, `@r`, `#(+ %1 %2)` with `%`, `%N`, `%&`.
- `#_ x`, stacked `#_ #_ x y z`, and `#_` between a prefix and its
  target.
- `^:kw x`, `^{:a 1} x`, `^Type x`; on a duplicate key the outer `^`
  wins.
- Keywords and symbols, including non-ASCII names; at most one `/`,
  neither side empty; `/` alone is division.
- Named chars `\newline \space \tab \return \formfeed \backspace`.
- Strings may span lines.
- `;` line comments and `(comment ...)`.
- `ns` with a docstring and `(:require [lib :as a :refer [f]])`, and
  `require`.

### 4.2 Reader divergences

| Construct | Clojure | nexis | Why |
|---|---|---|---|
| Radix integer | `2r101`, `16rFF` | only `0x` and `0b` prefixes | a smaller grammar |
| `+42` | the integer 42 | a symbol | no signed-variant tokens |
| Ratio `22/7` | a Ratio | `:bad-number-literal` | no rationals (§23 #10) |
| `42N` | a BigInt | `42`; any integer literal reads as an integer, and one beyond i64 is a bignum | one integer domain (§23 #10) |
| `3.14M` | a BigDecimal | `:bad-number-literal` | no decimals |
| `017` | octal 15 | decimal 17 | one decimal spelling |
| `1.` | `1.0` | `:bad-number-literal` | a real has digits on both sides of the dot |
| `1abc`, `1-2` | "Invalid number" | `:bad-number-literal` for the whole token | a number token ends where a symbol would |
| `##NaN`, `##Inf` | symbolic values | parse error | `(/ 0.0 0)` and `(/ 1.0 0)` produce them |
| `☃` | a char | `:invalid-char-literal`; write `\u{2603}` | one escape form (§23 #26) |
| `"☃"` | a string escape | `:invalid-string-escape`; write `"\u{2603}"` | the same |
| `\o377` | an octal char | unsupported | `\u{...}` covers it |
| String escapes | `\b \f \0`, octal, `\uHHHH` | `\n \t \r \\ \" \u{HEX}` | a narrow set |
| `#'foo` | `(var foo)` | parse error; write `(var foo)` | a minimal reader |
| `#:ns{:a 1}`, `::k` | namespaced map, auto-resolved keyword | parse error | no current namespace at read time |
| `#?(...)` | reader conditional | parse error | one target (PLAN §4) |
| `#inst`, `#uuid` | tagged literals | parse error | PLAN §4, §24 #3 |
| `#"re"` | a regex | parse error | no regex (§24 #9) |
| `#=(...)`, `#<...>`, `#^{...}` | read-eval, unreadable, old metadata | parse error | no read-time evaluation; one `^` spelling |
| `#!` | a comment to end of line | the CLI treats a first line starting `#!` as a comment; elsewhere a parse error | executable scripts only |

The `#` dispatch set is `#{}`, `#(...)` and `#_`. Clojure's reader
throws ad-hoc exceptions for malformed input; nexis reports a stable
keyword (`:duplicate-literal-key`, `:map-odd-count`, `:invalid-symbol`,
`:nested-anon-fn`, `:unquote-outside-syntax-quote`, ...; PLAN §28.3).

### 4.3 Semantic divergences

| Expression | Clojure | nexis | Owner |
|---|---|---|---|
| `(= 1 1.0)` | true | false; `(== 1 1.0)` is true | §23 #11 |
| NaN `=` NaN | false | true (canonical bits) | `docs/SEMANTICS.md` |
| integer overflow | `+` throws, `+'` promotes | every integer operator promotes to a bignum and demotes a result that fits i48 | `docs/BIGNUM.md` |
| inexact `(/ a b)` of integers | a Ratio | an f64; exact quotients stay integers | §23 #10 |
| `(long x)` | throws beyond 64 bits | never rejects a size (`(long 1e30)` is a bignum); NaN or infinity is `:invalid-argument`; `int` is `long`; `short`, `byte`, `float`, `bigint` do not exist | `docs/SEMANTICS.md` |
| `map`, `filter`, `for`, `keys`, `cons` | lazy seqs | eager lists; no `lazy-seq`, no transducer arities | §23 #14 |
| `(range)`, `(iterate f x)`, `(repeat x)`, `(repeatedly f)` | infinite | arity errors; pass a count: `(range n)`, `(iterate f x n)`, `(repeat n x)`, `(repeatedly n f)` | §23 #14 |
| `(empty record)` | throws | `{}`: a record is a map to collection functions | `docs/PROTOCOLS.md` |
| `extend-type`, `extend-protocol` | a class | a kind keyword (`:fixnum`, `:string`, `:vector`, `:any`) or a record name | `docs/PROTOCOLS.md` |
| `(catch Exception e ...)` | by class | a class-name symbol, `:default` and `any` take every value; `(catch :tag e ...)` takes `:tag`, a map whose `:error` is `:tag`, or an `ex-info` whose data's `:error` is `:tag` | `docs/MACROEXPAND.md` |
| `(ex-info msg data)` | an `ExceptionInfo` | the map `{:message msg :data data}` (`:cause` with a third argument) | `docs/MACROEXPAND.md` |
| `(case x ...)` with no match | `IllegalArgumentException` | throws `{:error :no-matching-clause :message "No matching clause: x" :value x}`; `condp` the same | `docs/MACROEXPAND.md` |
| `(reduced x)` | an opaque box | a `nexis.core/Reduced` record with field `:val`; `reduce`, `reductions` and `reduce-kv` honour it | `src/stdlib/core.nx` |
| `(read-string s)` | the full reader | the first form as data; syntax-quote, unquote and `^meta` are not data and raise `:reader-error` | `docs/MACROEXPAND.md` |
| `(eval form)` | binds `*ns*` | compiles in the current namespace as the REPL does; a compile error is the catchable map `{:error :compile-error :message ... :form form}` | `docs/MACROEXPAND.md` |
| `(macroexpand form)` | with `&env` | no lexical environment; subforms never expand | `docs/MACROEXPAND.md` |
| `(meta f)`, `(with-meta 'sym m)`, `(with-meta rec m)` | metadata on fns, symbols and records | nil; `:no-metadata-on-immediate` | `docs/SEMANTICS.md` §7 |
| `volatile!`, `vswap!`, `vreset!` | a volatile box | an atom (`atom?` is true) | `docs/ATOM.md` |
| `(exit n)` | `System/exit` | the same: closes open stores and ends the process; no `finally` runs | `src/stdlib.zig` |
| string indexes | UTF-16 code units | code points: `count`, `subs`, `nth` and `nexis.string/index-of` count them | `docs/STDLIB.md` §2 |
| `(format "%s" nil)` | `"null"` | `"nil"` | `docs/STDLIB.md` §2 |
| `long-array`, `aget`, `aset` | mutable Java arrays | immutable typed vectors `(i64-vector xs)`, `(f64-vector xs)`, never `=` to a vector; kernels in `nexis.simd` | `docs/TYPED_VECTOR.md` |
| `instance?`, `class`, `type` | JVM classes | absent; kind predicates (`string?`, `map?`, ...) | — |

### 4.4 Absences

The deliberate ones are PLAN §4's non-goals: multimethods, STM,
agents, `core.async`, lazy sequences, regex, reader conditionals,
tagged literals, rationals and decimals, full hygiene, other compile
targets, Java interop. Library functions that do not exist yet
(`sorted-map`, `sorted-set`, transducers and others) are known gaps,
not decisions (`HANDOFF.md`).
