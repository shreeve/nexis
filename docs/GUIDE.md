# GUIDE.md — nexis for Clojure programmers

nexis is Clojure's language on a runtime of its own: one native binary
with a compiler, a bytecode VM, persistent collections and a garbage
collector, plus durable refs and Nextomic, a Datomic-class database,
in the same process. If you write Clojure you can write nexis today;
this guide is the list of what to expect, what to unlearn, and where
to look things up. It is the user's account; `CLOJURE-REVIEW.md` is
the implementer's, with every difference in full.

---

## 1. Getting around

```bash
nexis repl                      # a REPL; :quit or Ctrl-D to leave
nexis run app.nx a b            # run a file; *command-line-args* is ["a" "b"]
nexis app.nx                    # the same, for a file ending .nx
nexis -e '(+ 1 2)'              # evaluate and print each non-nil value
nexis test test/*.nx            # run the files, then every deftest; exit 1 on failure
nexis doc map                   # print map's documentation
nexis disasm app.nx             # the bytecode, with source positions
```

The documentation lives in the binary, as in a Clojure REPL, and
every public function and macro of the library has a docstring:

```clojure
(doc map)                ; arglists and docstring
(doc if)                 ; special forms and host macros too
(doc nexis.string)       ; a namespace
(dir nexis.string)       ; every public name in a namespace
(apropos "split")        ; (nexis.core/split-at ... nexis.string/split-lines)
(find-doc "lazy")        ; every docstring that matches
```

A file runs top to bottom, one form at a time, but every name it
defines is known before the first form runs: a function may call one
defined further down, and a misspelled name is a compile error before
anything runs.

```text
$ nexis run typo.nx
nexis: typo.nx:2:14: compile error: unable to resolve symbol: lenght
    (defn f [x] (lenght x))
                 ^^^^^^
```

The REPL keeps `*1`, `*2`, `*3` and `*e` as Clojure's does.

---

## 2. What is the same

The surface is Clojure's, read by the same rules:

- Literals: lists, vectors, maps, sets, keywords, symbols, strings,
  characters (`\a`, `\newline`, `é`), `nil`, `true`, `false`,
  integers, doubles, `##Inf` and `##NaN`, regexes `#"..."`.
- Reader sugar: `'x`, `` `x ``, `~x`, `~@xs`, `@r`, `#'v`,
  `#(+ % %2)`, `#_` discards, `^:private` and `^{...}` metadata.
- Special forms and the core macros: `def`, `if`, `do`, `let`, `fn`,
  `loop`/`recur`, `try`/`catch`/`finally`, `defn`, `defmacro` with
  syntax-quote and auto-gensyms, `cond`, `case`, `condp`, `->`, `->>`,
  `cond->`, `some->`, `as->`, `doto`, `when-let`, `if-some`, `for`,
  `doseq`, `dotimes`, `letfn`, `binding`.
- Destructuring everywhere a binding appears, including keyword
  arguments after `&`, `:keys`/`:strs`/`:syms`, `:or` and `:as`.
- Persistent vectors, hash maps and sets, sorted maps and sets,
  transients, lazy and chunked sequences, transducers, `reduced`.
- Atoms with validators and watches, dynamic Vars and `binding`,
  delays, metadata on Vars and collections.
- Protocols, records, `extend-type`, `extend-protocol`, multimethods
  with hierarchies, `derive`, `isa?` and `prefer-method`.
- Namespaces with `ns`, `require` (`:as`, `:refer`, `:rename`, prefix
  lists), `in-ns`, `resolve`, `ns-publics`.
- `nexis.test` is `clojure.test`: `deftest`, `is`, `are`, `testing`,
  `thrown?`, fixtures, `run-tests`.

Most Clojure code that uses none of the JVM runs unchanged:

```clojure
(ns port.core (:require [clojure.string :as str]))

(defn slug [s]
  (-> s str/lower-case (str/replace #"[^a-z0-9]+" "-")))

(slug "Hello, World 2026")   ;=> "hello-world-2026"
```

---

## 3. What differs, and why

### 3.1 No JVM, so no interop

nexis does not run on the JVM, so there are no classes to call:
`(Math/sqrt 2)`, `(.toUpperCase s)`, `(String. b)`, `(Exception.
"x")`, `import` and `java.*` names do not exist and fail to compile
as unresolved symbols. Each has a nexis spelling:

| Clojure on the JVM | nexis |
|---|---|
| `(Math/sqrt x)`, `(Math/pow x y)`, `Math/PI` | `(nexis.math/sqrt x)`, `(nexis.math/pow x y)`, `nexis.math/PI`; or require `clojure.math` |
| `(.toUpperCase s)`, `(.contains s "x")` | `(str/upper-case s)`, `(str/includes? s "x")` |
| `(throw (Exception. "boom"))` | `(throw (ex-info "boom" {}))`, or throw any value (§3.3) |
| `(instance? String x)`, `(instance? Long x)` | `(string? x)`, `(int? x)`; `(class x)` is a keyword such as `:string` |
| `(System/currentTimeMillis)`, `(System/nanoTime)` | `(nano-time)`, a monotonic clock in nanoseconds |
| `(System/exit 1)` | `(exit 1)` |
| `#inst`, `#uuid`, `java.util.UUID` | no tagged literals; `(random-uuid)` and `(parse-uuid s)` work on the UUID's string |
| `(long-array n)`, `aget`, `aset` | immutable typed vectors: `(i64-vector xs)`, `(f64-vector xs)` |

`class` and `type` return a kind keyword (`:vector`, `:fixnum`,
`:string`) or a record's type, which a multimethod dispatching on
`class` takes as its dispatch values. `extend-type` and
`extend-protocol` take those too, or a Clojure class name standing for
its kinds (`String`, `Long`, `Object` for anything).

Reader conditionals (`#?(...)`), tagged literals, auto-resolved
keywords (`::k`) and namespaced map literals (`#:ns{...}`) are not
read: nexis has one target, and no namespace at read time.

### 3.2 One thread

A nexis program is one isolate on one thread. There is no `future`,
`promise`, `pmap`, `agent`, STM (`ref`, `dosync`) or `core.async`.
Atoms are the in-memory mutable cell, with Clojure's API (`swap!`,
`reset!`, `compare-and-set!`, validators, watches); `volatile!` makes
an atom. For state that outlives the process, and for sharing between
processes, there are durable refs (§5) and Nextomic (§6): their
transactions are serialized by the store.

### 3.3 Exceptions are values

Anything can be thrown, and `catch` matches by tag, not by class:

```clojure
(try (throw :out-of-stock)
     (catch :out-of-stock _ "sold out"))              ;=> "sold out"

(try (throw (ex-info "no such user" {:error :not-found :id 7}))
     (catch :not-found e [(ex-message e) (:id (ex-data e))]))
;=> ["no such user" 7]

(try (/ 1 0)
     (catch :divide-by-zero _ :undefined))            ;=> :undefined

(try (nth [1 2] 5)
     (catch any e :out-of-range))                     ;=> :out-of-range
```

A catch clause's matcher is one of:

- a keyword `:tag`: matches the thrown value `:tag` itself, a map or
  record whose `:error` is `:tag`, or an `ex-info` whose data's
  `:error` is `:tag`;
- `any` or `:default`: matches every value;
- a Java class name: `ArithmeticException` stands for
  `:divide-by-zero` and `:arithmetic-overflow`,
  `IndexOutOfBoundsException` for `:index-out-of-bounds`,
  `ClassCastException` for `:kind-mismatch`, and so on; any other
  class name (`Exception`, `Throwable`) matches every value, so
  ported `try` forms keep working.

The runtime's own errors are thrown under such tags (`:kind-mismatch`,
`:arity-mismatch`, `:index-out-of-bounds`, `:divide-by-zero`,
`:stack-overflow`, `:no-matching-clause`), and the library's under
namespaced ones (`:db/busy`, `:nextomic/unique`). `ex-info` builds a
plain map, `{:message msg :data data}`, so it prints and compares as
data. An uncaught error ends `nexis run` with exit status 5 and a
report naming the source position and the call stack.

### 3.4 Numbers

nexis has two integer representations and one floating type:

- Integers are 48-bit fixnums inside the value and become bignums when
  they grow past that, then shrink back when a result fits. No integer
  operation overflows or throws: `+`, `*`, `inc` and the rest are
  Clojure's `+'`, `*'` and `inc'`, which are the same functions here.
  `(* 99999999999 99999999999)` is `9999999999800000000001`.
- Doubles are IEEE f64. `float` and `double` both give one.
- There are no ratios and no decimals. `(/ 6 3)` is `2`, but `(/ 1 3)`
  is the double `0.3333333333333333`; `1/3` and `1.5M` are reader
  errors.
- `=` does not cross the integer/float line: `(= 1 1.0)` is false and
  `(== 1 1.0)` is true, as with Clojure's longs and doubles. `##NaN`
  is `=` to itself.
- `0x1F` and `0b101` read; `2r101` and the octal `017` do not (`017`
  is seventeen).

### 3.5 A function calls itself directly

`defn` names its function, and a recursive call in its body goes to
that function, not through the Var. In Clojure a recursive call goes
through `#'f`, so redefining `f` at the REPL changes what an older
copy of `f` calls; in nexis the older copy keeps calling itself:

```clojure
(defn countdown [n] (if (zero? n) :old (countdown (dec n))))
(def saved countdown)
(defn countdown [n] :new)
(saved 3)                  ;=> :old  (Clojure: :new)
```

Calls to other functions go through their Vars as usual, so
redefining a helper is seen at once. Write `(#'f ...)` for a
recursive call that should follow redefinition.

### 3.6 Strings

String functions live in `nexis.string`, which is Clojure's
`clojure.string`: requiring `clojure.string` gives the same Vars under
that name, and so do `clojure.set`, `clojure.walk`, `clojure.edn`,
`clojure.math`, `clojure.test` and `clojure.pprint`. Any library
namespace can be called qualified without a `require`
(`(nexis.string/join ", " xs)`); the `clojure.*` names exist once
required.

Strings are UTF-8, and `count`, `subs`, `nth` and `str/index-of`
count code points, not UTF-16 units: `(count "héllo")` is 5 and
`(subs "héllo" 1 3)` is `"él"`. `str/split` takes a string separator
as well as a regex. `(format "%s" nil)` is `"nil"`.

### 3.7 Regular expressions

`#"..."` uses Java's syntax and nexis's own engine, which matches in
time linear in the input whatever the pattern. That rules out what
needs backtracking: backreferences (`\1`), lookahead and lookbehind,
atomic groups, possessive quantifiers. A pattern literal is compiled
when the file is read, so one of those is a reader error before the
program runs:

```text
nexis: app.nx:3:10: reader error: :invalid-regex backreferences are not supported at index 3
```

`re-pattern` throws `{:error :invalid-regex ...}` for the same text
at run time. Everything else is as in Clojure: `re-find`,
`re-matches`, `re-seq`, `re-matcher`, `re-groups`, named groups,
`(?i)` and the other flags, `\p{L}` classes, and `$1` or `${name}`
in `str/replace`. `docs/REGEX.md` §6 lists the differences.

### 3.8 Smaller differences

- **Namespaces are symbols.** `*ns*` and `(the-ns 'user)` are the
  symbol `user`; `ns-publics` and `resolve` return Vars as usual.
- **Vars carry less metadata.** `(meta #'f)` has `:name`, `:ns`,
  `:arglists`, `:doc` and what the definition added, but no `:file`
  or `:line`, so there is no `source`.
- **UUIDs are strings**, in canonical lowercase form.
- **Map entries are vectors**: `(map-entry? [:a 1])` is true.
- **Laziness** is Clojure's, chunked where Clojure's is, but `apply`
  realizes its last argument, and a lazy seq a closure captures keeps
  its head (`docs/LAZY.md` §9).
- **A record type is a symbol** (`user.Point`); `(instance? Point p)`
  reads as in Clojure.
- **Functions carry no metadata**, and neither do symbols; collections,
  records and Vars do.

---

## 4. The namespaces in the binary

`nexis.core` is referred into every namespace. The others are there
without a file; call them qualified, or `require` them for an alias.

| Namespace | Clojure name | What it holds |
|---|---|---|
| `nexis.core` | `clojure.core` | the language and its library |
| `nexis.string` | `clojure.string` | `join`, `split`, `replace`, `trim`, `upper-case`, `includes?`, ... |
| `nexis.set` | `clojure.set` | `union`, `intersection`, `difference`, `select`, `rename-keys`, ... |
| `nexis.walk` | `clojure.walk` | `postwalk`, `prewalk`, `keywordize-keys`, `macroexpand-all`, ... |
| `nexis.edn` | `clojure.edn` | `read-string`, evaluating nothing |
| `nexis.math` | `clojure.math` | `sqrt`, `pow`, `sin`, `log`, `floor`, `ceil`, `round`, `PI`, `E`, ... |
| `nexis.test` | `clojure.test` | `deftest`, `is`, `are`, `testing`, `run-tests`, fixtures |
| `nexis.pprint` | `clojure.pprint` | `pprint`, `pprint-str` |
| `nexis.simd` | | kernels over typed vectors: `sum`, `dot`, `scale`, `map` |
| `db` | | durable refs (§5) |
| `nextomic` | | the database (§6); required as `[nextomic :as d]` by convention |

Your own namespaces load from files: `(require '[my.app-util :as u])`
loads `my/app_util.nx` from the working directory or the directory
of the running file, whose first form is `(ns my.app-util ...)`.
`(dir nexis.string)` lists what a namespace holds.

---

## 5. Durable refs

A durable ref names a value in a store file: a connection, a tree and
a key. Deref reads it; transactions write it. Every value nexis can
print can be stored, collections nested to any depth included, and it
reads back equal.

```clojure
(def conn (db/open "tmp/shop.edb"))           ; creates the file
(def apples (db/ref conn :inventory :apples)) ; tree :inventory, key :apples

(db/put-key! apples 10)       ; one write in its own transaction
@apples                       ;=> 10

(with-tx [tx conn]            ; several writes, all or nothing
  (db/alter! tx apples - 3)
  (db/put! tx (db/ref conn :inventory :pears) 4))
@apples                       ;=> 7

(try (with-tx [tx conn]       ; a throw rolls the transaction back
       (db/alter! tx apples - 100)
       (when (neg? (db/get tx apples)) (throw :out-of-stock)))
     (catch :out-of-stock _ :refused))
@apples                       ;=> 7

(with-read-tx [tx conn]       ; a consistent snapshot of a whole tree
  (db/scan tx :inventory))    ;=> [["apples" 7] ["pears" 4]]

(db/close conn)
```

- A write transaction sees its own writes; a read transaction sees the
  store as of when it began. A file has one writer at a time: another
  process's write waits for the lock, and a second write transaction
  in the same process is `:db/busy`.
- `db/scan` and `db/reduce-tree` walk a tree in key order; keys come
  back as strings, which `db/ref` takes back.
- Every commit waits for the disk unless the connection says
  otherwise: `(db/open path {:durability :commit})` skips the sync
  for speed, and `db/sync` and `db/close` then make every earlier
  commit durable. `docs/DB.md` §3.3 says what each setting keeps
  through a crash.
- A store file carries between machines but not between nexis
  releases (README "Versions and stores").

`examples/durable-refs.nx` and `examples/todo-app.nx` are complete
programs; `docs/DB.md` §12 is the reference.

---

## 6. Nextomic

Nextomic is Datomic's model in the same binary and one file: facts
are datoms `[entity attribute value tx added]`, the store keeps every
fact it was ever told, a database value is an immutable view at a
point in time, and queries are Datalog over data.

```clojure
(require '[nextomic :as d])
(def conn (d/connect "tmp/people.edb"))

;; The schema is data, transacted like any other.
(d/transact! conn [{:db/ident :person/email :db/valueType :db.type/string
                    :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
                   {:db/ident :person/name :db/valueType :db.type/string
                    :db/cardinality :db.cardinality/one}
                   {:db/ident :person/langs :db/valueType :db.type/keyword
                    :db/cardinality :db.cardinality/many}])

(d/transact! conn [{:person/email "ada@example.org" :person/name "Ada"
                    :person/langs [:clojure :zig]}])
(def before (d/db conn))      ; a value: it never changes
(d/transact! conn [{:person/email "ada@example.org" :person/name "Ada Lovelace"}])
                              ; upserts Ada by her unique email

(d/q '[:find ?name . :where [?e :person/email "ada@example.org"] [?e :person/name ?name]]
     (d/db conn))             ;=> "Ada Lovelace"
(:person/name (d/entity before [:person/email "ada@example.org"]))
                              ;=> "Ada": the past is still there
(d/pull (d/db conn) [:person/name :person/langs] [:person/email "ada@example.org"])
                              ;=> {:db/id ..., :person/name "Ada Lovelace", :person/langs [:clojure :zig]}

;; Try a change without keeping it.
(d/with conn [[:db/retractEntity [:person/email "ada@example.org"]]]
  (fn [db-after report] (d/entity db-after [:person/email "ada@example.org"])))
                              ;=> nil, and the store is unchanged

(d/release conn)
```

What it has: tempids and lookup refs, upserts on unique identity,
cardinality many, components, `:db.fn/cas` and transaction functions,
the four indexes through `d/datoms` and `d/index-range`, Datalog with
rules (recursive ones included), predicates, function bindings,
`not`, `or`, aggregates and pull expressions in `:find`, `d/pull`
with nested, reverse and component patterns, lazy entities, `as-of`,
`since`, `history`, `tx-range`, speculative `with`, excision and
fulltext search. `d/explain` prints the plan a query would run.
`d/with-conn` connects for the extent of a body.

What differs from Datomic: it is embedded, one process writing at a
time, with no peer, transactor or server. `d/with` takes the
connection and a function of the speculative database, and
`d/tx-range` the connection. An instant is milliseconds as an
integer. A function in a query clause is one of the built-ins or any
Var the symbol resolves to, as the compiler resolves it, so
`clojure.string/starts-with?` works once `clojure.string` is
required. `docs/NEXTOMIC.md` §12 lists the rest.

`examples/nextomic-app.nx` is a clinic chart that tours the API;
`docs/NEXTOMIC.md` is the reference, §6 for the functions.

---

## 7. The command line

| Command | What it does |
|---|---|
| `nexis run FILE [ARG...]` | Runs FILE; prints only what it prints. FILE `-` reads the program from stdin. |
| `nexis FILE [ARG...]` | The same, for a FILE that ends `.nx` or exists; a `#!/usr/bin/env nexis` first line makes a script executable. |
| `nexis -e EXPR [ARG...]` | Evaluates EXPR and prints each value that is not nil. |
| `nexis repl` | The REPL. |
| `nexis test FILE...` | Runs the files, then every `deftest` they defined; exit 1 on a failure or error. |
| `nexis doc NAME` | Prints `(doc NAME)`: a function, macro, special form or namespace. |
| `nexis disasm FILE` | Compiles FILE without running it and prints its bytecode. |
| `nexis --help`, `nexis --version` | Usage, version. |

Exit status: 0 success, 1 a usage error or a failing test run, 2 an
unreadable file, 3 a parse or reader error, 4 a compile error, 5 an
uncaught runtime error, `n` for `(exit n)`. `docs/TOOLING.md` §1 has
the full contract, including the environment variables.

---

## 8. Further reading

- `examples/README.md`: example programs in reading order.
- `CLOJURE-REVIEW.md`: every difference from Clojure in tables, with
  the reason and the spec that owns it.
- `docs/README.md`: one specification per module; `docs/STDLIB.md` for
  the library, `docs/LAZY.md` for sequences, `docs/REGEX.md`,
  `docs/DB.md`, `docs/NEXTOMIC.md`.
