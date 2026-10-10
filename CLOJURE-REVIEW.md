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
| Sequences | lazy, chunked by 32 | lazy, chunked where Clojure's are, locals cleared at their last move (§23 #14, `docs/LAZY.md`) |
| Identity | Vars, atoms, refs (STM), agents | Vars, atoms, durable refs over emdb; no STM or agents (§23 #5, #6) |
| Polymorphism | protocols, records, multimethods | protocols, records, multimethods (§23 #8) |
| Transactions | STM `dosync` | emdb read and write transactions, lexically scoped |
| History | none built in | `db/snapshot`; Nextomic `as-of`, `since`, `history` (§23 #22) |
| Macros | `&form`, `&env`, full `core.clj` | arguments only (§23 #34); host macros in Zig plus `core.nx` |
| Concurrency | threads, futures, `core.async` | one isolate, one thread (§23 #5) |

---

## 1. Taken

### 1.1 Compiler primitives and macro layering

Clojure's compiler knows a small set of special forms; `let`, `fn`,
`loop`, `letfn` and `defn` are macros over `let*`, `fn*`, `loop*` and
`letfn*`, and destructuring and docstrings live in the macros, while
`fn*` itself takes a clause per arity, `(fn* name? ([params] body)+)`,
which the compiler makes one method each. nexis keeps the split (§23
#31) and the clauses: a `fn*` with several compiles to a routine per
clause over one arity table, and a call enters the clause its count
picks (`docs/COMPILER.md` §5.5, `docs/VM.md` §5). The difference is where
the macros live: `let`, `fn`, `loop`, `defn`, `cond`, `->` and the
other surface forms are host macros written in Zig in the expander,
complete from the start; `core.clj`'s two-stage bootstrap (a trivial
`let`, redefined once destructuring exists) has no counterpart.
`letfn`, `binding` and the rest of the library macros are in
`src/stdlib/core.nx` (`docs/MACROEXPAND.md`).

### 1.2 Transient ownership

`ATransientMap.ensureEditable` checks ownership on every operation, and
`persistent!` ends it. nexis transients check an owner token on every
operation and freeze on `persistent!` (`docs/TRANSIENT.md` §5). As in Clojure, an
operation edits the nodes the transient owns in place and copies a
shared node once; the token lives in the node header's hash field,
which an internal node does not use (`docs/TRANSIENT.md`).

### 1.3 `seq` as the iteration abstraction

Every collection has a `seq` view, and `first`, `rest`, `next` and
`count` are written against it (§23 #35). Map lookup, vector indexing
and typed-vector kernels stay direct.

### 1.4 Callable keywords and symbols

`Keyword` implements `IFn` as `get`; so does `Symbol`. In nexis `(:k m)`
and `(:k m d)` are `get`, a symbol in function position looks itself up
the same way, and maps, sets and vectors are callable (§23 #33). A
Var is callable as in Clojure: `(#'f x)` calls the Var's value.

### 1.5 Unbound Vars

A declared, unbound Var holds a sentinel; calling or loading it raises
`:unbound-var`. Clojure's `Var.Unbound` is a callable that throws; the
effect is the same.

### 1.6 Metadata

Metadata never affects `=` or `hash` (§23 #12); `with-meta` returns a
new value with the map in the heap header. Collections, records and
Vars carry it, and `conj`, `assoc` and the other updates keep it, as
in Clojure; functions, symbols and keywords carry none
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
- **3.7** STM, agents, `core.async`, reader conditionals and tagged
  literals (PLAN §4).

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
- Named chars `\newline \space \tab \return \formfeed \backspace`,
  and `\uXXXX` in a char or a string (a surrogate pair in a string is
  one character).
- `##Inf`, `##-Inf`, `##NaN`, which `pr-str` prints back.
- Strings may span lines.
- `;` line comments and `(comment ...)`.
- `ns` with a docstring and `(:require [lib :as a :refer [f]])`,
  prefix lists (`[app [c :as cc] d]`) included, and `require`.

### 4.2 Reader divergences

| Construct | Clojure | nexis | Why |
|---|---|---|---|
| Radix integer | `2r101`, `16rFF` | only `0x` and `0b` prefixes | a smaller grammar |
| Ratio `22/7` | a Ratio | `:bad-number-literal` | no rationals (§23 #10) |
| `42N` | a BigInt | `42`; any integer literal reads as an integer, and one beyond i64 is a bignum | one integer domain (§23 #10) |
| `3.14M` | a BigDecimal | `:bad-number-literal` | no decimals |
| `017` | octal 15 | decimal 17 | one decimal spelling |
| `1.` | `1.0` | `:bad-number-literal` | a real has digits on both sides of the dot |
| `1abc`, `1-2` | "Invalid number" | `:bad-number-literal` for the whole token | a number token ends where a symbol would |
| `\o377` | an octal char | unsupported | `\uHHHH` and `\u{...}` cover it |
| String escapes | `\b \f`, octal, `\uHHHH` | Clojure's, and `\u{HEX}` | `\u{HEX}` names any scalar in one escape (§23 #26) |
| `#:ns{:a 1}`, `::k` | namespaced map, auto-resolved keyword | parse error | no current namespace at read time |
| `#?(...)` | reader conditional | parse error | one target (PLAN §4) |
| `#inst`, `#uuid` | tagged literals | parse error; `nexis.time/parse` reads an instant's text | PLAN §4, §24 #3 |
| `#"re"` | a `Pattern` | a pattern, compiled when the source is read; a construct that needs backtracking is `:invalid-regex` | a linear-time engine (`docs/REGEX.md`) |
| `#=(...)`, `#<...>`, `#^{...}` | read-eval, unreadable, old metadata | parse error | no read-time evaluation; one `^` spelling |

The `#` dispatch set is `#{}`, `#(...)`, `#_`, `#'` (`#'foo` is
`(var foo)`) and `#"..."`. Clojure's reader
throws ad-hoc exceptions for malformed input; nexis reports a stable
keyword (`:duplicate-literal-key`, `:map-odd-count`, `:invalid-symbol`,
`:nested-anon-fn`, `:unquote-outside-syntax-quote`, ...; PLAN §28.3).

### 4.3 Semantic divergences

| Expression | Clojure | nexis | Owner |
|---|---|---|---|
| `(= 1 1.0)` | true | false; `(== 1 1.0)` is true | §23 #11 |
| NaN `=` NaN | false | true (canonical bits) | `docs/SEMANTICS.md` |
| integer overflow | `+` throws, `+'` promotes | every integer operator promotes to a bignum and demotes a result that fits i48; `+'` and its kin are the same functions, and `unchecked-add` and its kin wrap two longs at 64 bits as Clojure's do | `docs/BIGNUM.md`, `docs/SEMANTICS.md` §2.2 |
| inexact `(/ a b)` of integers | a Ratio | an f64; exact quotients stay integers | §23 #10 |
| `(long x)` | throws beyond 64 bits; NaN is 0 | never rejects a size (`(long 1e30)` is a bignum); NaN is 0, as in Clojure, and an infinity is `:invalid-argument`; `int`, `short` and `byte` check Java's ranges and make NaN 0, as Clojure's do; `float` checks the float range and returns the f64 unrounded; `bigint` and `biginteger` are `long`, since an integer of any size is one kind | `docs/SEMANTICS.md` §2.2, `docs/STDLIB.md` §2 |
| the seq of a map, set, string, or of a list `sort` or `keys` builds | walked one element at a time | a vector's view past three elements, so `map` over it takes 32 at a time | `docs/LAZY.md` §9 |
| a lazy seq a local holds | let go as it is walked (locals clearing) | let go as it is walked, but for the cases `docs/LAZY.md` §9 lists (a last read in place, a local a closure captures, a native that walks without consuming) | `docs/LAZY.md` §9, `docs/COMPILER.md` §4.9 |
| `(apply f (range))` | can stay lazy | does not end: `apply` realizes its last argument | `docs/LAZY.md` §9 |
| `(str (map inc [1]))` | `"clojure.lang.LazySeq@..."` | `"(2)"` | `docs/LAZY.md` §9 |
| `compare` of two strings | UTF-16 code-unit order (`String.compareTo`) | code-point order, the order of their UTF-8 bytes, which matches nexis's code-point string indexes; the two differ between U+E000–U+FFFF and the supplementary planes: `(compare "\uffff" "😀")` is 10178 in Clojure, −1 in nexis | `docs/SORTED.md` §6 |
| a lazy key of a map of up to eight entries (`assoc`, `frequencies`, `group-by`) | left unrealized: the array map compares and hashes nothing | realized when the map takes it, its throw raised by that call, as a hash set's in both | `docs/LAZY.md` §9 |
| a lazy seq nested in a value `=` or `hash` compares, whose body makes much garbage | collected while the body runs | nothing is collected until the body returns (it realizes in isolation, under `gc_hold`), so memory grows with the body's garbage | `docs/LAZY.md` §9 |
| a `lazy-seq` body that throws, walked again | `LazySeq.force` calls the body again, a `^:once` fn whose captured locals it had read are cleared: a body that reads its seq first (every core sequence function's) ends the seq there, one that reads no captured local runs again whole, one that uses a cleared local otherwise throws a `NullPointerException` | ends the seq at the block in every case, as babashka; `realized?` false until that walk, as both | `docs/LAZY.md` §4 |
| a lazy body that forces its own seq before it returns (`(map f v)` whose `f` walks the seq it is producing) | runs the body again inside itself: a body that does so once, under a flag, computes its elements twice; one that always does ends in `StackOverflowError` | the inner walk raises `:stack-overflow` at once, which ends the seq at the block unless the body catches it | `docs/LAZY.md` §4 |
| a `sequence` step that throws, walked again | goes on from the advanced source and transducer, dropping the chunk it was filling: `(3 4)` for a `(comp (map f) (take 4))` over `(range 10)` whose `f` throws once at 2 | ends the seq at the block: `()` | `docs/LAZY.md` §9 |
| `(empty record)` | throws | `{}`: a record is a map to collection functions | `docs/PROTOCOLS.md` |
| `extend-type`, `extend-protocol` | a class | a kind keyword (`:fixnum`, `:string`, `:vector`, `:any`), `nil`, a record name, or a common Clojure class name standing for its kinds (`String`, `Long`, `Object` as `:any`) | `docs/PROTOCOLS.md` |
| `(catch Exception e ...)` | by class | a class that names a nexis error takes that error's tag (`ArithmeticException` `:divide-by-zero` and `:arithmetic-overflow`, `IndexOutOfBoundsException` `:index-out-of-bounds`, `ClassCastException` `:kind-mismatch` and `:not-callable`, `IllegalArgumentException` `:invalid-argument`, `:no-matching-clause`, `:arity-mismatch`, `:no-method` and `:ambiguous-method`, `IllegalStateException` `:preference-conflict`, `AssertionError` `:assertion-failed`, `StackOverflowError` `:stack-overflow`); any other class-name symbol, `:default` and `any` take every value; `(catch :tag e ...)` takes `:tag`, a map whose `:error` is `:tag`, or an `ex-info` whose data's `:error` is `:tag` | `docs/MACROEXPAND.md` |
| `(ex-info msg data)` | an `ExceptionInfo` | the map `{:message msg :data data}` (`:cause` with a third argument); as Clojure's, `msg` is a string or nil and `data` a map, nil meaning `{}`, else `:kind-mismatch` | `docs/STDLIB.md` §8 |
| a runtime error caught, `(try (+ 1 "a") (catch Exception e e))` | a `ClassCastException` with a message and a stack trace | the error map `{:error :kind-mismatch :message "+ expects numbers, got a string" :fn "f" :file "app.nx" :line 3 :column 5}`, placed at the program's own frame; `ex-message` reads its message, `ex-data` is the map itself, `ex-cause` nil; the frame chain is in the uncaught report only; the bare keyword when memory is exhausted | `docs/VM.md` §13 |
| `(case x ...)` with no match | `IllegalArgumentException` | throws `{:error :no-matching-clause :message "No matching clause: x" :value x}`; `condp` the same | `docs/MACROEXPAND.md` |
| `(reduced x)` | an opaque box | a `nexis.core/Reduced` record with field `:val`; `reduce`, `reductions`, `reduce-kv` and `run!` honour it | `src/stdlib/core.nx` |
| `(read-string s)`, `(read-string opts s)` | the full reader; `opts` takes `:eof`, `:read-cond` and `:features` | the first form as data, `^meta` on a collection kept (on a symbol dropped); syntax-quote and unquote are not data and raise `:reader-error`; `opts` takes `:eof`, the value of a string that holds no form | `docs/STDLIB.md` §2 |
| `clojure.math` | doubles in and out; `floor` and `ceil` of a long give a double | `nexis.math`: the same functions over doubles, except that `floor` and `ceil` give an integer back unchanged (`(floor 3)` is `3`, Clojure's `3.0`), and `floor-div` of `Long/MIN_VALUE` by `-1` is `2^63`, a bignum, where Java's wraps to `Long/MIN_VALUE`, since every integer operator promotes (`docs/SEMANTICS.md` §2.2); the last bit of a transcendental result is the platform library's | `docs/TOOLING.md` §4 |
| `clojure.edn/read-string` | the EDN reader: no reader sugar, tagged literals through `:readers` and `:default` | `nexis.edn/read-string`, the nexis reader with `{:eof nil}`: `'x`, `@x` and `#()` read as the forms they stand for, and a tagged literal is a `:reader-error` whatever `:readers` holds (there are none, PLAN §4); nothing is evaluated | `docs/STDLIB.md` §4 |
| `(eval form)` | binds `*ns*` | compiles in the current namespace as the REPL does; a compile error is the catchable map `{:error :compile-error :message sentence :form form :kind name}` | `docs/MACROEXPAND.md` |
| `(macroexpand form)` | with `&env` | no lexical environment; subforms never expand | `docs/MACROEXPAND.md` |
| `(with-meta inc m)`, `(with-meta 'sym m)` | metadata on native fns and symbols | `:kind-mismatch`; `:no-metadata-on-immediate` (a `fn` carries metadata) | `docs/SEMANTICS.md` §7 |
| `(meta #'f)` | `:name`, `:ns`, `:arglists`, `:line`, `:column`, `:file` | `:name`, `:ns` (the namespace's name symbol), `:arglists` for a `defn` or `defmacro`, and what the definition carries; no `:line`, `:column` or `:file` | `docs/MACROEXPAND.md` §10 |
| `not` and `mod` at a call site | ordinary calls through the Var (neither has `:inline`), so `with-redefs` or `alter-var-root` of either reaches a compiled call | inlined, as `+`, `inc` and the comparisons (which have `:inline` in Clojure) are: a redefinition reaches `apply` and higher-order uses, not a compiled `(not x)` or `(mod a b)` | `docs/COMPILER.md` §4.3 |
| a `defn` calling itself | through the Var `#'f`: once `f` is redefined, the earlier function's recursive calls reach the new one | through its own name (`defn` names its fn): the earlier function keeps calling itself, and `(#'f ...)` is the call through the Var | `docs/COMPILER.md` §4.3, §5.5 |
| `volatile!`, `vswap!`, `vreset!` | a volatile box | an atom (`atom?` is true) | `docs/ATOM.md` |
| `(exit n)` | `System/exit` | the same: closes open stores and ends the process; no `finally` runs | `src/stdlib.zig` |
| string indexes | UTF-16 code units | code points: `count`, `subs`, `nth` and `nexis.string/index-of` count them | `docs/STDLIB.md` §2 |
| `(pr-str (char 0))`, an ASCII control without a name, DEL | `\` and the raw byte | `\u{0}`, `\u{7F}`: escaped, as in a string; any other char prints as Clojure's (`\é`) | `docs/SEMANTICS.md` §6.4 |
| `(format "%s" nil)` | `"null"` | `"nil"` | `docs/STDLIB.md` §2 |
| `/` by a float zero | `ArithmeticException` when both operands are boxed (a function's arguments, `apply`); IEEE `##Inf`/`##NaN` when the compiler sees a primitive double operand (a float literal, a double local): `(/ 1.0 0)` at the REPL is `##Inf` | `:divide-by-zero` always, the boxed rule: nexis has no primitive operand types; a NaN operand is the result, as in Clojure | `docs/SEMANTICS.md` §2.2 |
| `long-array`, `aget`, `aset` | mutable Java arrays | immutable typed vectors `(i64-vector xs)`, `(f64-vector xs)`, never `=` to a vector; kernels in `nexis.simd` | `docs/TYPED_VECTOR.md` |
| `class`, `type`, `instance?` | JVM classes; `(instance? Number x)` walks the hierarchy | a kind keyword (`:vector`, `:fixnum`) or a record's symbol (`user.P`), which `instance?` compares for equality; `defrecord` binds `P` to that symbol, so `(instance? P x)` reads as in Clojure; `class?` holds of these, and the global hierarchy takes them as tags (`docs/STDLIB.md` §9.1) | `docs/STDLIB.md` §8 |
| `isa?`, `parents`, `ancestors`, `descendants` | walk Java's superclasses and interfaces as well as the hierarchy (`(isa? java.util.HashMap java.util.Map)`); `descendants` of a class throws; `(isa? h c p)` of a non-hierarchy `h` throws | only the edges `derive` made: there is no supertype relation between kinds; `descendants` reads the hierarchy for any tag; a non-hierarchy `h` gives false. The tags `class?` holds of, kind keywords and record symbols, stand for classes: `(derive :vector :user/coll)`, `(derive Circle :user/shape)`; a redefined record is the same symbol and keeps its derivations, where Clojure's is a new class | `docs/STDLIB.md` §9.1 |
| a multimethod | a `MultiFn`: `(fn? mf)` false, `class` `clojure.lang.MultiFn`, printed `#object[clojure.lang.MultiFn ...]` | a closure: `(fn? mf)` true, `class` `:function`, printed `#<fn>`; `ifn?`, `=`, `hash`, `meta` and `with-meta` agree with Clojure | `docs/STDLIB.md` §9.2 |
| `(defmulti ^:private f ...)`, `(defmulti ^{:doc "d"} f ...)` | the metadata on the name lands on the Var | dropped: a `core.nx` macro never sees `^meta` on a symbol; the docstring and attr-map arguments do land on the Var | `docs/STDLIB.md` §9.2 |
| the no-method and preference messages | `"... dispatch value: null"` | `"... dispatch value: nil"`, as `format`'s `%s` prints nil | `docs/STDLIB.md` §9.4 |
| the ambiguity message's pair | `PersistentHashMap` order | the method table's: insertion order to eight entries, CHAMP order past them, so the two keys named can be in the other order | `docs/STDLIB.md` §9.4 |
| namespaces | `Namespace` objects | their name symbols: `(the-ns 'user)` and `*ns*` in `user` are `user`; `ns-publics` and `resolve` return Vars as Clojure's do, and a host macro resolves to nil; a `binding` of `*ns*` does not change where `eval` compiles | `docs/STDLIB.md` §8 |
| `(random-uuid)`, `(parse-uuid s)` | a `java.util.UUID`, printed `#uuid "..."` | the canonical lowercase string; `uuid?` is true of a string in that form | `docs/STDLIB.md` §8 |
| `(System/getenv)`, `(System/getenv name)` | static methods | `nexis.sys/getenv`; bytes that are not UTF-8 read as U+FFFD | `docs/STDLIB.md` §11 |
| `clojure.java.shell/sh` | `:in` a string, bytes, a stream, a reader or a file; `:in-enc`, `:out-enc` (`:bytes`) | `nexis.shell/sh`, also required as `clojure.java.shell`: `:in` a string, no encodings (`:invalid-argument`); a signal's `:exit` is 128 plus its number, as Java's | `docs/STDLIB.md` §11 |
| instants | `java.util.Date` and `java.time.Instant` extend `Inst`, printed `#inst "..."` | `nexis.time.Instant`, a record of epoch milliseconds that extends `Inst`, printed `#nexis.time.Instant{:ms n}`; `nexis.time` parses and formats ISO-8601 in UTC; an Instant is not `compare`-able | `docs/STDLIB.md` §8, §12 |
| `clojure.data.json` | keys and keyword values written by `name`; non-ASCII and `/` escaped by default; unknown options ignored | `nexis.json`, also required as `clojure.data.json`: a keyword written whole (`"person/name"`); nothing escaped past JSON's need and U+2028/U+2029 unless `:escape-unicode` or `:escape-slash`; an unknown option is `:invalid-argument`; an Instant written as its ISO-8601 text; malformed text is `{:error :json-error :message :json-line :json-column}`, placed as any error | `docs/STDLIB.md` §13 |
| `(list? (seq [1 2]))`, and of `rest`, `(cons 1 ())`, `keys`, `sort` | false: each is a seq class of its own (`ChunkedSeq`, `Cons`, `KeySeq`, `ArraySeq`), and `list?` holds of a `PersistentList` only | true: a realized seq is a list, there being no seq kinds beside the list and the lazy seq (a vector's seq is a view of it); false of a lazy seq (`map`, `range`, a `cons` onto one) | `docs/LIST.md` §1 |
| `(map-entry? [:a 1])` | false: a map entry is a `MapEntry` | true: a map's entries are two-element vectors | `docs/STDLIB.md` §8 |
| `(float x)` | a 32-bit float | the f64 itself, after Java's range check | `docs/SEMANTICS.md` §2.2 |
| `tap>` | taps run on another thread | taps run before `tap>` returns | `docs/STDLIB.md` §8 |
| regular expressions | `java.util.regex`, a backtracking matcher | Java's syntax, each search in linear time: backreferences, lookaround, atomic groups, possessive quantifiers, Unicode scripts, blocks and binary properties and `(?U)` are `:invalid-regex`; a pattern past a limit of `docs/REGEX.md` §4 (10 000 instructions, a bound past 1000, ...) is too; an empty match advances one code point, not one UTF-16 unit; a capture inside a repeated group comes from the path that matched | `docs/REGEX.md` §6 |
| `(re-pattern "(")`, `(replace s re "$2")` | `PatternSyntaxException`, `IndexOutOfBoundsException` | `{:error :invalid-regex :message M :pattern P :index I}`, `{:error :invalid-replacement :message M}` with Java's sentences | `docs/REGEX.md` §9, §11 |
| `(split s ",")` | `split` takes a pattern only | a string separator splits on its occurrences, as a pattern matching only it would | `docs/STDLIB.md` §3 |

### 4.4 Absences

The deliberate ones are PLAN §4's non-goals: STM,
agents, `core.async`, reader conditionals,
tagged literals, rationals and decimals, full hygiene, other compile
targets, Java interop. Library functions that do not exist are known gaps, not decisions
(`HANDOFF.md` §6).
