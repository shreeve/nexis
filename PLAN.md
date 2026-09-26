# PLAN.md — nexis

> A Lisp where immutable values, transactional durable identity, and
> historical snapshots are one coherent programming model.

nexis is a Lisp with Clojure semantics on its own Zig 0.16 runtime
(reader, macroexpander, compiler, bytecode VM, persistent collections,
16-byte tagged value, precise GC), shipped as one binary that starts
instantly, with durable refs over the emdb storage engine and Nextomic,
a Datomic-class database, in the same process and file. It is not a
Clojure port: no Java interop, no STM, one isolate, one thread.

It stands on three sibling projects: **nexus** generates the parser
(`nexis.grammar` → `src/parser.zig`), **emdb** is the storage engine
(memory-mapped copy-on-write B+ trees, MVCC, named trees; nexis makes
zero changes to it), and **em**, a MUMPS engine, is the model for the
64-bit instruction shape and the slot VM.

**What this file holds.** The decisions: design principles (§3),
non-goals (§4), the three-representation discipline (§5), the frozen
decisions (§23), open questions (§24), risks (§25), the canonical Form
schema (§28, Appendix C) and the Amendment Log. How each module works
is in `docs/` (`docs/README.md` maps module to spec); the state of the
tree, its known gaps and the order of work are in `HANDOFF.md`; the
reading order, owner's rules and authority order are in `AGENTS.md`.

**Section numbers are stable.** §0–§2, §6–§22, §26 and §27 moved to the
documents that own their facts; the redirect table below resolves every
"PLAN §N" reference in the tree.

**Changing a decision.** A change to §23 or §28 is a dated Amendment Log
entry stating the decision and its reason, and the same commit rewrites
the frozen text and every document it supersedes.

---

## Redirect table

| Old § | Topic | Owner |
|---|---|---|
| preamble | reading order, discipline | `AGENTS.md` |
| §0 | summary, mission | this header; `README.md` |
| §1 | positioning | `README.md`; §4 |
| §2, §2.1 | substrate, prior art | this header; §23 #3, #23 |
| §6.1 | primitive core, surface macros | §23 #31; `docs/COMPILER.md` (primitive core lowering); `docs/MACROEXPAND.md` (host macro table) |
| §6.2 | truthiness | §23 #13; `docs/SEMANTICS.md` (truthiness) |
| §6.3 | equality, hashing | §23 #11, #12; `docs/SEMANTICS.md` (equality, hashing) |
| §6.4 | errors, `try`/`catch` | Amendment 2026-09-18 "Exceptions are values"; `docs/MACROEXPAND.md` (`try`); `docs/VM.md` (execution errors) |
| §6.5 | nil propagation (frozen) | `docs/SEMANTICS.md` (nil propagation) |
| §6.6 | collection equality categories (frozen) | §23 #36; `docs/SEMANTICS.md` (collections and `=`) |
| §6.7 | `seq` | §23 #14, #35 |
| §7.1–§7.2 | reader grammar | `nexis.grammar`; §28.2–§28.3; `docs/FORMS.md`; `CLOJURE-REVIEW.md` (reader divergences) |
| §7.3 | metadata sugar | §28.3 |
| §7.4 | Form vs Sexp | §28.1, §28.4 |
| §8.1 | Value layout | §23 #1; `docs/VALUE.md` (the 16-byte cell) |
| §8.2 | value kinds, heap header | `docs/VALUE.md` (kind table); `docs/HEAP.md` (header) |
| §8.3 | number tower | §23 #10, #11; `docs/SEMANTICS.md` (numbers); `docs/BIGNUM.md` |
| §8.4 | interning, keyword/symbol asymmetry | §23 #32; `docs/INTERN.md`; `docs/SEMANTICS.md` (interning) |
| §8.5 | metadata and the attachability matrix (frozen) | §23 #12, #32; `docs/SEMANTICS.md` (metadata matrix) |
| §8.6 | durable refs | §23 #7; `docs/DB.md` |
| §8.7 | keyword-as-function | §23 #33; `docs/VM.md` (call path) |
| §9.1 | map and set | §23 #37; `docs/CHAMP.md` |
| §9.2 | vector | §23 #30; `docs/VECTOR.md` |
| §9.3 | list | `docs/LIST.md` |
| §9.4 | transients | `docs/TRANSIENT.md` |
| §9.5 | typed vectors | `docs/TYPED_VECTOR.md` |
| §9.6 | complexity | `docs/CHAMP.md`, `docs/VECTOR.md`, `docs/LIST.md` |
| §9.7 | storage-native collections | §23 #4 |
| §10.1–§10.3 | collector strategy | §23 #2, #18; `docs/GC.md` |
| §10.4 | allocator | `docs/HEAP.md` |
| §10.5–§10.6 | roots, trigger | Amendment 2026-09-18 "The collector runs"; `docs/GC.md` (roots; cycle and trigger) |
| §10.7 | compile-time arena | `docs/COMPILER.md` (arena model) |
| §11.1–§11.2 | pipeline, stage duties | §28.4; `docs/COMPILER.md` (pipeline) |
| §11.3 | tail calls | §23 #19; `docs/COMPILER.md` (`recur`) |
| §11.4 | literals, constants | `docs/COMPILER.md` |
| §11.5 | compile errors | `docs/COMPILER.md` (error reporting); `docs/TOOLING.md` |
| §12.1 | instruction format | `docs/VM.md` (instruction format) |
| §12.2 | operand kinds (frozen) | §23 #21; `docs/VM.md` (operand kinds) |
| §12.3–§12.5 | opcode groups, dispatcher | `docs/VM.md` (opcode groups, dispatch) |
| §12.6 | object files | none exist (§24 #4) |
| §13.1–§13.2 | VM, functions, closures | `docs/VM.md` |
| §13.3–§13.4 | Vars, dynamic binding | §23 #20; Amendment 2026-09-18 "Dynamic Vars"; `docs/VM.md` (Vars, dynamic binding) |
| §13.5 | unwinding, stack traces | `docs/VM.md` (execution errors); `docs/TOOLING.md` |
| §13.6 | REPL | `docs/TOOLING.md` (commands) |
| §14.1–§14.2 | macros, syntax-quote | §23 #16, #29, #34; `docs/MACROEXPAND.md` |
| §14.3–§14.4 | namespaces, `require` | `docs/MACROEXPAND.md` (namespaces and the loader) |
| §15.1–§15.9 | connections, refs, transactions, snapshots, scans | §23 #6, #7, #22; `docs/DB.md` |
| §15.10 | serializable kinds (frozen) | §23 #25; `docs/CODEC.md` (scope, non-serializable kinds) |
| §15.11, NX-1–NX-6 | Nextomic | `docs/NEXTOMIC.md` §1 (commitments), §2 (store layout) |
| §16 | concurrency | §23 #5 |
| §17 | standard library | `HANDOFF.md` (namespace inventory); `README.md` (language tour); `bin/nexis --help` |
| §18 | CLI, REPL, test runner, disassembler | `docs/TOOLING.md` |
| §19 | SIMD, performance | `docs/PERF.md`; `docs/BENCH.md`; `docs/TYPED_VECTOR.md` |
| §20.1–§20.2 | test layers, property laws #1–#8 | `HANDOFF.md` (what is proven); `test/README.md` |
| §20.3 | build steps | `AGENTS.md` (build steps) |
| §21 | roadmap | `HANDOFF.md` (known gaps, order of work) |
| §22 | repository layout | `AGENTS.md` (layout) |
| §26 (Appendix A) | comparison with Clojure | `CLOJURE-REVIEW.md` |
| §27 (Appendix B) | worked examples | `examples/*.nx` (run by `zig build examples`); `README.md` |

---

## 3. Design Principles

Every architectural decision is checkable against these.

1. **Values first.** The unit of programming is an immutable value.
   Update produces a new value with structural sharing.
2. **Identity separate from value.** A Var, an atom or a durable ref
   has an identity whose value may change over time. Identity and value
   are never confused.
3. **Persistent by default.** Maps and sets are CHAMP tries, vectors
   32-way tries with a tail. Mutation is opt-in through transients.
4. **Heap values and durable values share semantics, not
   representation.** Two values are equal iff `=` says so, whether one
   lives on the heap and the other was decoded from emdb.
5. **Durable identity is explicit.** There is no "maybe durable" value.
   A durable ref is a distinct, visibly named kind.
6. **One coherent model.** One story for values, identities,
   transactions and persistence.
7. **Minimal reader, macro-powered surface.** The reader handles only
   what cannot be a macro: literals, collection punctuation,
   quote/unquote/deref/metadata.
8. **Interactive development is first-class.** REPL redefinition,
   `macroexpand`, the disassembler and `doc` are part of the language.
9. **Explicit, predictable performance.** No hidden laziness, no
   surprise boxing, no implicit allocation in hot loops.
10. **Separation of concerns.** Form, runtime Value and durable encoding
    are three layers (§5). They share conventions; they never fuse.
11. **Boring first.** Start with the simplest thing known to work.
    Optimize only with measurements.

Be less ambitious in representation unification and more ambitious in
semantic clarity. nexis should feel like a clean, sharp Lisp with
excellent immutable data and an explicit durable-identity model, not a
Clojure clone with a bespoke VM, a database with Lisp syntax, or a
half-merged heap and storage.

---

## 4. Non-Goals

What nexis deliberately does not ship. Each is a decision, not an
oversight; widening this list or removing a row takes an amendment.

| Feature | Rationale |
|---|---|
| Multimethods | Protocols (§23 #8) cover type-based polymorphism. |
| Software transactional memory | emdb transactions are the language's transaction story; a second concurrency model is a trap. |
| Agents, `core.async` | One thread (§23 #5); a scheduling model is a large semantic sink. |
| Reader conditionals `#?(...)` | One compile target. |
| Tagged literals `#inst`, `#uuid` | Rich literals are functions or macros (§24 #3). |
| Rationals, decimals | The number tower is fixnum + bignum + f64 (§23 #10). |
| Lazy sequences | Every sequence function is eager (§23 #14; §24 #2). |
| Forcing every fast path through `seq` | `seq` is the iteration abstraction (§23 #35); map lookup, vector indexing and typed-vector kernels stay direct. |
| Regular expressions | No regex literal and no regex library (§24 #9). |
| Multiple compile targets | Zig-native only. |
| Multi-isolate runtime, parallelism | One process, one isolate, one thread (§23 #5). |
| Threads, futures, promises, `pmap` | Same. |
| Content-addressed values | Changes hash stability and identity semantics (§24 #6). |
| Time-travel debugging | As-of reads on durable state exist (§23 #22); execution replay does not. |
| Full hygienic macros | Auto-gensym and syntax-quote qualification only (§23 #16). |
| Validators, watches | Atoms are plain cells (`docs/ATOM.md`). |
| Type inference, gradual typing | Dynamic typing only (§24 #5). |
| Native code generation (JIT, AOT) | Bytecode only (§24 #4). |
| Java interop, FFI beyond Zig | No host language; natives are Zig. |

---

## 5. Three Representations (kept distinct)

The most important discipline in the design.

**Layer 1 — Form.** What the reader produces from source text and what
macros and the compiler consume: `Form = {datum, origin}`, a tree of
syntactic data with a source span on every node (§28). Metadata written
in source is a `with-meta` datum, not a field.

**Layer 2 — runtime Value.** What bytecode manipulates: a 16-byte
tagged cell (§23 #1). Immediates are nil, booleans, chars, fixnums
(i48), floats (f64), keywords and symbols (intern ids); every other
kind is a pointer to a heap object with a shared header
(`docs/VALUE.md`, `docs/HEAP.md`). Collections compare structurally;
Vars, atoms and durable refs by identity.

**Layer 3 — durable encoding.** The bytes the codec writes to emdb: a
two-byte version envelope, then a kind-tagged payload; keywords and
symbols travel as text, never as intern ids (`docs/CODEC.md`). The
round-trip invariant: `decode(encode(v))` is `=` to `v` and hashes the
same, for every serializable kind (§23 #25).

**The layers do not leak into each other.** The compiler lifts a Form
into a Value only through `quote`; a macro receives its arguments as
Values converted from Forms and its result is converted back
(`docs/MACROEXPAND.md`); the storage layer never reads a Value's bytes,
it always goes through the codec.

---

## 23. Hard Decisions (Frozen)

Each item is a commitment; changing one takes an Amendment Log entry
(see the header). The numbers are stable and cited across the tree.

1. **16-byte tagged Value**, not NaN-boxed, not 24-byte.
2. **Tracing mark-sweep GC**, not reference counting, not hybrid.
3. **Slot/register VM**, not a stack VM, on em's 64-bit instruction
   shape.
4. **Heap-first persistent collections.** No mmap-native collections;
   a collection is persisted by encoding it (§5).
5. **One isolate, one thread.** No threads, no parallelism.
6. **Explicit lexical transactions.** No ambient transaction, no STM.
7. **Durable refs are identities**, not cached values; their equality
   and hash come from the identity alone.
8. **Protocols and records, no multimethods.** `defprotocol`,
   `defrecord`, `extend-type` and `extend-protocol` build per-VM
   registries with run-time dispatch (Amendment 2026-05-19;
   `docs/PROTOCOLS.md`); like any Var, a record or protocol may be
   redefined, as in Clojure.
9. **No multimethods, agents, `core.async` or reader conditionals.**
10. **Integers are fixnum + bignum. Floats are f64.** No rationals, no
    decimals.
11. **`(= 1 1.0)` is `false`.** Cross-type numeric equality is `==`.
12. **Metadata never affects equality or hash.**
13. **Only `nil` and `false` are falsy.**
14. **Eager.** Every sequence function returns a realized collection:
    `map`, `filter`, `for` and friends return lists; there are no lazy
    sequences, so `(range)` and `(iterate f x)` without a bound are
    arity errors (`(range n)`, `(iterate f x n)`).
15. **The reader is minimal.** Sugar is macros.
16. **Syntax-quote has auto-gensym, not full hygiene.**
17. **Three representations (Form, Value, encoded) are kept distinct**
    (§5).
18. **Mark-sweep first; generational only if measurements demand it.**
19. **Only `recur` elides frames.** `recur` is guaranteed
    constant-space; every other call, in tail position or not, pushes a
    frame, and `call:tailcall` is a reserved opcode that traps.
20. **Vars are the redefinition mechanism.** A call through a global
    name goes through its Var, so it sees the latest root; lexical
    locals and captured upvalues compile directly. The one exception
    is the arithmetic and comparison operators the compiler inlines
    when the name resolves to `nexis.core`'s own Var
    (`docs/COMPILER.md`).
21. **Operand kinds.** Each operand is `[kind:4][index:12]`. The
    hot-path kinds are `S`=0 slot, `C`=1 constant, `V`=2 Var, `U`=3
    upvalue; `J`=5 is a jump target; `I`=4 (intern id) and `E`=6
    (durable-ref literal) are reserved and no opcode resolves them
    (`docs/VM.md`). A 12-bit jump index bounds a routine at 4096
    instructions.
22. **As-of reads exist.** `db/snapshot` and `with-snapshot` pin an
    emdb MVCC read; Nextomic's `as-of`, `since` and `history` read
    tx-in-key history.
23. **LMDB is emdb's ancestor; Datomic is the semantic reference for
    durable-as-value.** When a choice is ambiguous, ask first what
    LMDB, Datomic, Clojure and LuaJIT do.
24. **Form is `{datum, origin}`** (§28.1). No side tables, no
    annotation field; source metadata is the `with-meta` datum. Macros
    see and produce Forms (§5).
25. **Serialization has a fixed scope.** Serializable: nil, bool,
    char, fixnum, bignum, f64, string, keyword and symbol (as text),
    list, vector, map, set, typed vector. Everything else (functions,
    Vars, atoms, transients, durable refs, byte vectors, records,
    protocols, db and Nextomic handles) is not; encoding one raises the
    keyword `:unserializable` (`docs/CODEC.md`). Nesting depth is
    unbounded.
26. **Character and string escapes are unified on `\u{HEX}`.** Named
    chars for the common set; single-char `\a` syntax.
27. **No block comments.** `;` (line), `#_` (discard the next form),
    `(comment ...)` (a macro that yields nil).
28. **`#(...)` is lowered after reading**: the reader produces an
    anon-fn datum (printed `#%anon-fn`), the macroexpander turns it
    into `fn*`. A nested `#(...)` is a reader error.
29. **Backtick reads as `syntax-quote`**, with Clojure-style
    qualification and auto-gensym in the macroexpander.
30. **The persistent vector is a plain 32-way trie with a tail.** No
    RRB relaxation; this matches Clojure's vector.
31. **The compiler knows only the primitive core**: `let*`, `fn*`,
    `loop*`, `letfn*`, `def`, `if`, `do`, `quote`, `var`, `recur`,
    `try`, `throw`, and the internal `#%list`, `#%concat`, `#%vector`,
    `#%map` and `#%set` that syntax-quote emits. `let`, `fn`, `loop`,
    `defn` and the other surface forms are host macros in the
    expander, `letfn` a macro in `src/stdlib/core.nx`
    (`docs/MACROEXPAND.md`); the expander rewrites `ns`, `require`,
    `defmacro` and `set!` before lowering.
32. **Keyword/symbol asymmetry.** Both are interned immediates.
    Keywords never carry metadata; symbols carry none either (the
    `meta_symbol` kind number is reserved), so `with-meta` on a symbol
    raises `:no-metadata-on-immediate`. Keyword and symbol hash
    domains are separated.
33. **Keywords, symbols and Vars are callable.** `(:k m)` is
    `(get m :k)`, `(:k m d)` is `(get m :k d)`, and a symbol in function
    position looks itself up the same way; a Var calls its value in
    force, `(#'inc 1)` is 2; maps, sets and vectors are callable as in
    Clojure.
34. **Macros receive their arguments only**: no `&form`, no `&env`.
35. **`seq` is the core iteration abstraction.** Map lookup, vector
    indexing and typed-vector kernels bypass it where that is clearer.
36. **Sequential equality crosses types.** Lists, vectors and their
    seq views are equal when element-wise equal; maps and sets are
    categories of their own; hashes are built so the invariant holds.
37. **CHAMP is the persistent map and set**: separate data and node
    bitmaps, canonical layout.
38. **Performance is a first-class goal.** A performance claim is a
    measured ReleaseFast number (`docs/PERF.md`); a comparison with
    Clojure is published only from same-machine numbers, the cases
    Clojure wins included (`docs/BENCH.md`).

**Frozen tables owned by module docs.** These carry §23's weight; each
lives in one place:

- nil propagation on collection ops — `docs/SEMANTICS.md`;
- the three collection equality categories — `docs/SEMANTICS.md`;
- the metadata attachability matrix — `docs/SEMANTICS.md` §7;
- the serializable-kind table and wire format — `docs/CODEC.md`;
- the operand kinds and opcode groups — `docs/VM.md`;
- Nextomic's commitments (the former NX-1–NX-6) — `docs/NEXTOMIC.md` §1.

---

## 24. Open Questions

Deliberately undecided. The numbers are stable; closed questions are
removed.

- **#2 Laziness.** Every sequence function is eager and returns a list
  (§23 #14). Whether a lazy `seq` or a separate stream abstraction ever
  lands is open.
- **#3 Tagged literals.** A `#inst`-style literal would be a
  macro-based reader extension, not a reader feature.
- **#4 AOT and bytecode caches.** Programs compile from source on every
  run; there is no object-file format.
- **#5 Schema or spec language.** None exists.
- **#6 Content-addressed values.** Excluded: they change the hash
  stability rules.
- **#7 Concurrency across isolates.** Depends on a multi-isolate
  runtime, which §23 #5 excludes.
- **#8 A network REPL (nREPL-style).** None exists.
- **#9 Regular expressions.** Which engine, if any: none ships.
- **#13 `&form` and `&env`.** §23 #34 keeps them out; `&form` would be
  cheap (the Form is in hand), `&env` needs the lexical environment at
  the expansion site.

---

## 25. Risk Register

The numbers are stable; retired risks are removed.

| # | Risk | Mitigation |
|---|---|---|
| 1 | Semantic drift between Form, Value and encoding | §5 and §23 #17; every new kind is checked against all three layers, and adding one takes an amendment. |
| 2 | GC bugs that corrupt the heap | Precise roots; `test/prop/gc.zig`; `NEXIS_GC_STRESS=1` collects every 4 KiB, and the `test/nextomic` scripts always run under it; the native rooting rule (`docs/GC.md` §11.5). |
| 3 | Equality or hash drift between heap and decoded values | `test/prop/codec.zig` checks round-trip equality and hash. |
| 4 | Transient misuse | Every transient op checks the wrapper's state; `test/prop/transient.zig`. |
| 5 | Runaway macro expansion or deep input | The expansion depth limit (256, `MacroDepthExceeded`) and the native stack guard: recursion on user-controlled depth raises `:stack-overflow` (`src/stack.zig`, `docs/VM.md`). |
| 6 | Tail-call elision hurting debuggability | Only `recur` elides frames (§23 #19). |
| 7 | emdb changes underneath nexis | emdb is a path dependency (`../emdb`); nexis tests assert nexis's contracts, not engine internals, so a change shows as a failing contract. |
| 8 | Zig stdlib churn | `build.zig.zon` pins `minimum_zig_version` 0.16.0; `ZIG-0.16.0.md` records the idioms the tree uses. |
| 10 | Scope creep toward Clojure compatibility | §4 is doctrine. |
| 12 | The codec boundary creeps (functions, Vars, records) | §23 #25 names the serializable set; anything else raises `:unserializable`. |
| 13 | Numeric corner cases poison equality, hash or codec | `docs/SEMANTICS.md` pins every numeric edge case. |
| 15 | Durable-ref reads outside a transaction see different states | Each `@r` outside a transaction is its own read; `with-read-tx` and `db/snapshot` give one consistent view (`docs/DB.md`). |
| 16 | Intern tables grow without bound in a long session | No mitigation: interning is permanent. |
| 17 | A held snapshot keeps the file from reclaiming pages | `db/release-snapshot!`; nothing reports held snapshots. |

---

## 28. Appendix C — Canonical Form Schema

The contract between the parser's output and the Form tree that macros
and the compiler consume. `test/golden/` is its executable
specification (§28.6); `docs/FORMS.md` owns the pretty-printer, span
policy, token-boundary rules and reader limits.

### 28.1 Form shape

```zig
pub const Form = struct {
    datum: Datum,     // §28.2
    origin: SrcSpan,  // { pos: u32, len: u32 }, byte offsets into the source
};
```

- `datum` is the form's content: an atom or a compound of Forms.
- `origin` is the span of the source construct that produced the Form;
  every Form has one.
- There is no metadata field: `^m x` reads as the `with-meta` datum
  (§28.2), and a macro sees `x` without it (a symbol carries no
  metadata, §23 #32).

### 28.2 Canonical datum shapes

```
;; Atoms
nil                                  ;; nil
true, false                          ;; bool
42, 0x2A, 0b101, 42N                 ;; int (any radix, within i64; N changes nothing)
18446744073709551616                 ;; bigint (an integer beyond i64, as decimal text)
3.14, 1e9, 1.5e-3                    ;; real (f64)
"hello"                              ;; string (UTF-8; may span lines)
\a, \newline, \u{2603}               ;; char (Unicode scalar)
:foo, :ns/foo                        ;; keyword
foo, ns/foo, set!, ->>, λ            ;; symbol

;; Compounds
(list   f1 f2 f3)                    ;; (...)
(vector f1 f2 f3)                    ;; [...]
(map    k1 v1 k2 v2)                 ;; {...}  flat key/value alternation
(set    f1 f2 f3)                    ;; #{...}

;; Reader macros
(quote             f)                ;; 'f
(syntax-quote      f)                ;; `f
(unquote           f)                ;; ~f
(unquote-splicing  f)                ;; ~@f
(deref             f)                ;; @f
(list (symbol var) f)                ;; #'f: an ordinary list, as in Clojure

;; Metadata
(with-meta TARGET META-MAP)          ;; ^meta x: META-MAP first in source, TARGET first in the Form

;; Internal (not user-addressable)
(#%anon-fn f1 f2 ...)                ;; #(...): the anon-fn datum holds the body forms
```

### 28.3 Reader-normalization rules

The transformations between the parser's `Sexp` tree and the Form tree,
all before macroexpansion.

| Source | Canonical Form |
|---|---|
| `^:kw x` | `(with-meta x {:kw true})` |
| `^{:a 1} x` | `(with-meta x {:a 1})` |
| `^sym x` | `(with-meta x {:tag sym})` |
| `^:a ^:b x` | `(with-meta x {:a true, :b true})`: one merged map; on a duplicate key the outer (leftmost) `^` wins |
| `#_ x y` | `x` is discarded; only `y` appears |
| `'#_ x y`, `^:m #_ x y` | a prefix reads the form after the discarded one: `(quote y)`, `(with-meta y {:m true})` |
| `#_ #_ x y z` | each `#_` consumes one form, which may itself begin with `#_`: only `z` remains |
| `#(body)` | `(#%anon-fn body)`; `%`, `%1`, `%2`, `%&` stay ordinary symbols for the macroexpander |
| `` `x `` | `(syntax-quote x)`, not expanded here |
| `#'x`, `#'(f)` | the list `(var x)`, `(var (f))`: `#'` reads the next form, as Clojure's reader does, and `var` rejects a non-symbol at compile time |
| `42N`, `0xFFN`, `18446744073709551616N` | the integer without the suffix |
| `"one⏎two"` | a string may span lines; the newline is part of it |
| `λ`, `ns.é/π`, `:ключ` | a symbol or keyword may hold non-ASCII UTF-8 |
| `{:a 1 :a 2}` | reader error `:duplicate-literal-key` |
| `{:a}` | reader error `:map-odd-count` |
| `#{1 1 2}` | reader error `:duplicate-literal-element` |
| `#(#(inc %))` | reader error `:nested-anon-fn` |
| `~x` outside `` `...` `` | reader error `:unquote-outside-syntax-quote` |
| `~@x` outside `` `...` `` | reader error `:unquote-splice-outside-syntax-quote` |
| `1abc`, `1-2`, `1/2`, `1.`, `3.14M` | reader error `:bad-number-literal` |
| `"a\qb"`, `"\u{D800}"` | reader error `:invalid-string-escape` |
| `A`, `\ab`, `\u{110000}` | reader error `:invalid-char-literal` |
| `foo/bar/baz`, `:foo/bar/baz` | reader error `:invalid-symbol`, `:invalid-keyword` |
| `^1 x` | reader error `:unknown-reader-construct` (metadata is a keyword, map or symbol) |
| bytes that are not UTF-8 in a string, symbol or keyword | reader error `:invalid-utf8` |
| a form nested past the native stack's budget | reader error `:nesting-too-deep` |
| `#"re"`, `##Inf`, `#?(...)`, `::k` | parse error naming the construct |

Only statically detectable literal keys and elements count as
duplicates: `{:a 1 (keyword "a") 2}` reads.

### 28.4 Stage ownership

| Stage | Input | Output | Responsibilities |
|---|---|---|---|
| **Parser** (`src/parser.zig`, generated by nexus; scanner `src/nexis.zig`) | source text | `Sexp` tree with spans | Tokenizing and LALR(1) parsing; drops `#_` and the form it discards. No other normalization. |
| **Reader** (`src/reader.zig`) | `Sexp` | canonical Form tree | The §28.3 rules: spans, metadata merging, `#(...)` to the anon-fn datum, the `syntax-quote` marker, the reader errors. |
| **Macroexpander** (`src/expand.zig`) | Form | expanded Form | Macros to a fixpoint; expands `syntax-quote` (qualification, auto-gensym, unquote and splice); turns the anon-fn datum into `fn*`; passes a macro its arguments only (§23 #34). |
| **Compiler** (`src/compile.zig`, `lowerForm`) | expanded Form | bytecode | Resolves symbols to slot, upvalue, Var or special form, reporting unresolved ones; lowers through the Tiny IR to bytecode (`docs/COMPILER.md`). |

`syntax-quote` expands in the macroexpander, not the reader, so the
reader stays independent of namespaces and tooling sees the backtick
structure.

### 28.5 Worked examples

The Form column is the golden pretty-printer's output
(`docs/FORMS.md`), joined onto one line.

| # | Source | Form |
|---|---|---|
| 1 | `^:private (defn foo [x] x)` | `(with-meta (list (symbol defn) (symbol foo) (vector (symbol x)) (symbol x)) (map (keyword :private) (bool true)))` |
| 2 | `^:dynamic ^{:doc "a var"} *out*` | `(with-meta (symbol *out*) (map (keyword :doc) (string "a var") (keyword :dynamic) (bool true)))` |
| 3 | `` `(if ~cond :yes :no) `` | `(syntax-quote (list (symbol if) (unquote (symbol cond)) (keyword :yes) (keyword :no)))` |
| 4 | `#(+ %1 %2)` | `(#%anon-fn (symbol +) (symbol %1) (symbol %2))` |
| 5 | `{:a 1 :b 2}` | `(map (keyword :a) (int 1) (keyword :b) (int 2))` |
| 6 | `(+ #_(expensive-thing) 1 2)` | `(list (symbol +) (int 1) (int 2))` |
| 7 | `@some-ref` | `(deref (symbol some-ref))` |
| 8 | `[\a \newline \u{2603}]` | `(vector (char \a) (char \newline) (char \u{2603}))` |
| 9 | `'foo`, `` `foo `` | `(quote (symbol foo))`, `(syntax-quote (symbol foo))` |
| 10 | `(+ -1 2)` | `(list (symbol +) (int -1) (int 2))` |

- **2.** The reader merges a `^` chain into one map, as Clojure's
  reader assoc's each outer `^` onto the metadata of the form it wraps:
  entries are gathered innermost first, and a duplicate key keeps the
  outer value.
- **3.** `syntax-quote` is a marker. The macroexpander rewrites this
  one to `(#%list (quote if) cond :yes :no)`: a list builds through
  `#%list`, a vector, map or set through `#%vector`, `#%map` or
  `#%set`, a splice through `#%concat` segments; special forms stay
  bare and other symbols are qualified (`docs/MACROEXPAND.md`).
- **4.** `%1` and `%2` are ordinary symbols here; the macroexpander
  rewrites the anon-fn to `(fn* [%1 %2] body)` after scanning the body.
- **8.** A char datum holds the Unicode scalar value.
- **9.** `quote` and `syntax-quote` are distinct datum variants,
  handled separately throughout.
- **10.** `-` followed directly by a digit at the start of a token
  begins a number, so `-1` is a literal, not `(- 1)`.

### 28.6 Golden test contract

`test/golden/reader-literals.{nx,sexp}` and `test/golden/basic.{nx,sexp}`
pass byte-for-byte, and each `test/golden/errors/*.nx` fails with the
reader error its `.err` names (`zig build golden`). A diff is a reader
regression.

---

## Amendment Log

PLAN.md is the highest-authority document in the project (AGENTS.md
authority order). Substantive changes are logged here, dated, each
entry stating the decision and its rationale.

- **2026-05-18 — Atoms added.** Appendix A's "Atoms — Removed" row
  was a v1 scoping decision. Atoms are in v1 as in-memory mutable
  cells consistent with §23 #5 (single-isolate, single-threaded): the
  Clojure-canonical API (`atom`/`reset!`/`swap!`/`swap-vals!`/
  `compare-and-set!`/`atom?` + `@a` via universal `deref`) is provided
  for source-portability, and `compare-and-set!` is a deterministic
  check-and-set under the single-threaded execution model — not a
  lock-free retry primitive. Validators, watches and metadata on atoms
  are absent. Full spec: `docs/ATOM.md`. No frozen decision in §23
  needed amending (the prior "Removed" line lived in Appendix A
  only); this log entry IS the authority record.

- **2026-05-19 — Protocols + records added.** §23 #8 ("No user
  protocols in v1") and Appendix A ("Protocols — Removed in v1") were
  v1-scoping decisions; this entry reframes them as scope additions,
  not changes to architecturally load-bearing decisions. v1 keeps
  §23 #5 (single-isolate, single-threaded), so protocols are
  static-dispatch + per-VM registries; no STM, no agents, no
  concurrency. Per-VM `RecordType` and `Protocol` registries; heap
  kinds 35–37 (`record` / `protocol` / `protocol_fn`); structural
  equality + hash for records; opaque identity for protocols /
  protocol_fns. Records + protocols are NOT in the §23 #25
  serializable set (`:unserializable`). Full spec: `docs/PROTOCOLS.md`.

- **2026-09-18 — Number tower contagion (§8.3 / §6.3).** Arithmetic
  and ordered comparison between fixnum and float follow Clojure
  contagion instead of raising `:type-error`; `==` is the cross-type
  numeric equality (§23 #11 keeps `(= 1 1.0)` false); `/` on two
  integers yields a float when the quotient is inexact, since §23 #10
  has no rationals. Fixnum overflow raises the catchable
  `:arithmetic-overflow`; there is no bignum arithmetic. SEMANTICS.md
  §2.2 and §6.3 track this entry.

- **2026-09-18 — Doubles; addendum to the number-tower entry.**
  Integer division by zero (`/`, `quot`, `rem`, `mod`) raises the
  catchable `:divide-by-zero`; float division by zero is IEEE
  (`(/ 1.0 0)` is `Infinity`). The fixnum payload is 48 bits
  (`value.zig`: `fixnum_max = 2^47 - 1`); an integer literal outside
  that range is the compile error `IntegerOutOfFixnumRange`. §23 #10
  ("fixnum + bignum") is realized as a `bignum` kind with codec and
  hashing and no arithmetic or literal lifting; both are listed in
  `HANDOFF.md` §4.

- **2026-09-18 — Keyword-as-function (§8.7, §23 #33).** `(:k m)` and
  `(:k m default)` are handled by the VM's call path for a keyword in
  function position; maps, sets and vectors are invocable the same
  way (`(m :k)`, `(#{1 2} 2)`, `([10 20] 1)`). §24 #11 is superseded;
  §8.7 and §23 #33 are the authority.

- **2026-09-18 — `q` is a native, not a macro (§15.11 NX-3).** The
  query is a value (vector or map form) parsed at run time into IR
  and cached per VM by heap identity and structural hash, so the
  parse cost NX-3 assigned to a macro is paid once per distinct query
  and the query stays data: composable, storable, buildable at run
  time. No bytecode-constant IR exists. `docs/NEXTOMIC.md` §1 #7 and
  §5 are the authority; macros over `q` are sugar only.

- **2026-09-18 — Nextomic index layout (§15.11 NX-4, NX-5, NX-6).**
  History is tx-in-key as NX-4 says, but current and history are
  separate trees: four current indexes (`nx/eavt`, `nx/aevt`,
  `nx/avet`, `nx/vaet`) hold only asserted facts and answer ordinary
  reads with no fold, their value being the logical `[t:6]`; four
  history indexes (`nx/*-h`) carry `(t << 1) | added` in the key and
  answer `as-of`/`since`/`history`; `nx/txlog`, `nx/idents` and
  `nx/sys` complete the eleven. `t` is Nextomic's own monotonic
  counter in `nx/sys`, never the engine's `txnId`. NX-6's
  `:nextomic/schema` tree does not exist: schema is datoms on
  attribute entities read as-of the basis. NX-5's `datom` heap kind
  does not exist; `datoms`, `tx-range` and `history` reads return
  `[e a v t added]` vectors, and the kind is listed as absent in
  `docs/NEXTOMIC.md` §6. `docs/NEXTOMIC.md` §1–§2 are the authority.

- **2026-09-18 — Exceptions are values; catch by keyword tag
  (§6.4, §13.5).** A thrown value is any value and there is no
  `:error` kind: an error that can say more travels as a map
  `{:error :tag ...}` (the shape `docs/NEXTOMIC.md` §7 and
  `case`'s no-match map use), one that cannot is the bare keyword.
  `(catch any e ...)` takes every value; `(catch :tag e ...)` takes
  the value `:tag`, a map whose `:error` entry is `:tag`, or an
  `ex-info` map whose data's `:error` is `:tag`; clauses are tried
  in order and an untaken value is rethrown through `finally`.
  `ex-info` builds `{:message m :data d}` (`:cause` when given) and
  `ex-data`/`ex-message` read it back. §6.4's `:kind` and
  `:trace` fields and its destructuring catch pattern are not
  shipped; `docs/MACROEXPAND.md` §10 and `docs/COMPILER.md` §5.10
  are the authority.

- **2026-09-18 — `as-of` removed from §21 "Beyond 1.0".** §23 #22
  makes `as-of` reads v1, and they exist twice: `db/snapshot` /
  `with-snapshot` over MVCC read transactions (§15.7) and Nextomic's
  `as-of`/`since`/`history` db-values over tx-in-key history.

- **2026-09-18 — Bignum arithmetic and literals (§8.3, §23 #10, §28.2).**
  The integer tower is fixnum + bignum as §23 #10 states: `+ - * /
  quot rem mod inc dec abs` and unary `-` promote an i48 overflow to a
  bignum and demote a result that fits back to a fixnum, ordering and
  the predicates are exact over bignums, contagion with f64 is
  unchanged, and no arithmetic raises `:arithmetic-overflow` (the
  keyword remains for a count or id that does not fit a fixnum). The
  reader's canonical datum set (§28.2) gains `bigint`, an integer
  literal beyond i64 as decimal text; `int` stays i64 and the
  compiler lifts either into a bignum constant. Bignums print in
  decimal with no suffix. `docs/BIGNUM.md` §9, `docs/SEMANTICS.md`
  §2.2 and §6.3 and `docs/FORMS.md` §3 track this entry; it
  supersedes the "until bignum arithmetic lands" clauses of the two
  number-tower entries above.

- **2026-09-18 — The collector runs (§10.5, §10.6).** The VM is the
  collector's host: it enumerates the §10.5 roots (every frame's
  slots, closure, cells and routine constants; every Var's root,
  metadata and thread binding; the dynamic-binding save stack; a
  root stack natives push callback results onto; pending throws; the
  protocol registry) and runs a cycle at one safe point, the
  instruction fetch, once the heap has allocated a threshold of bytes
  since the last cycle (§10.6: the larger of 16 MiB and the bytes
  that survived; `NEXIS_GC_STRESS` lowers it to 4 KiB). Closures and
  upvalue cells are heap blocks; Vars stay immortal arena objects
  rooted through the namespaces. `docs/GC.md` §3, §7 and
  `docs/VM.md` §9 are the authority.

- **2026-09-18 — Dynamic Vars and `binding` (§8, §13.4).** `(def
  ^:dynamic *x* ...)` marks a Var dynamic through its metadata;
  `binding` is a `core.nx` macro over `push-thread-bindings` /
  `pop-thread-bindings` with the pop in a `finally`, and `set!` a
  macro over `var-set`, which writes the innermost binding in force
  and never the root. The binding in force lives on the Var, so a
  load is one flag test; §13.4's `push-dynamic` / `pop-dynamic`
  opcodes do not exist, and the §8 sentence "`set!` does not exist"
  is replaced. `docs/VM.md` §6.5 is the authority.

- **2026-09-19 — The lazy entity kind (§8.2, §23 #25).**
  `nextomic_entity` (40) joins the heap kinds of `docs/VALUE.md`
  §2.2: `(d/entity db e)` returns a value holding the db-value and
  the eid that reads its attributes on access, one read per access at
  the db-value's basis and mode, a ref coming back as another lazy
  entity; `(d/touch ent)` is the eager map and `(d/entity-db ent)`
  the db-value. Two entities are equal when their db-values are equal
  and their eids agree. The kind is not serializable, as the other
  Nextomic handles are not (§23 #25 unchanged). `docs/NEXTOMIC.md`
  §6 is the authority.

- **2026-09-19 — Number token boundary and the `N` suffix (§7.2).** A
  token that begins with a digit, or `-` and a digit, ends where a
  symbol would; the symbol constituents that follow the digits belong
  to the token, so `1abc`, `1-2`, `1.5x` and `22/7` reach the reader
  whole and fail as `:bad-number-literal` at the token instead of
  reading as a number followed by a symbol. `42N` reads as `42`, in any
  radix and at any size: one integer domain (§23 #10) leaves the
  suffix nothing to mark. `docs/FORMS.md` §3 is the authority;
  `CLOJURE-REVIEW.md` §4.2 lists the spellings that differ from
  Clojure.

- **2026-09-25 — Revamp.** The frozen text is rewritten to what the
  code does; each change and its reason:
  - §23 #24, §28.1: Form is `{datum, origin}`; source metadata is the
    `with-meta` datum; there is no `ann` or `user_meta` field and
    `origin` is never null. The two-field Form is what the reader,
    expander and compiler were built on.
  - §23 #25, §15.10: durable refs and byte vectors are not
    serializable, and encoding any unserializable value raises the bare
    keyword `:unserializable`. A serialized ref could not name its
    connection when decoded; no byte-vector constructor exists.
  - §23 #32, §8.5: symbols carry no metadata (kind 29, `meta_symbol`,
    is reserved), and `docs/SEMANTICS.md` §7 is the one metadata
    matrix. No code path builds a metadata-bearing symbol.
  - §23 #19: only `recur` elides frames; `call:tailcall` is reserved
    and traps. The compiler emits no general tail call.
  - §23 #8: its body states the 2026-05-19 decision (protocols and
    records exist); `defrecord` and `defprotocol` may be redefined, as
    in Clojure, so reloading a file works.
  - §23 #33: symbols are callable like keywords, as in Clojure.
  - §23 #14: eager means `map`, `filter` and `for` return lists and no
    lazy sequence exists, so `(range)` and `(iterate f x)` need a
    bound. There are no cursors to be lazy at.
  - §7.2, §28.2–§28.3: strings may span lines and must be UTF-8;
    symbols and keywords may hold non-ASCII UTF-8; `#_` may stand
    between a prefix and its target; on a duplicate metadata key the
    outer `^` wins. These match Clojure's reader.
  - §23 #31, §28.4: the compiler also lowers the internal `#%list`,
    `#%concat`, `#%vector`, `#%map` and `#%set` forms syntax-quote
    emits, `defn` is a host macro, and the two-stage bootstrap does not
    exist (the surface macros are host macros in the expander); the
    §28.4 compiler row names `compile.zig`, since no resolver module
    exists; §28.5 example 3 shows the `#%` forms.
  - §23 #21: the `I` and `E` operand kinds are reserved (no opcode
    resolves them); `J` indexes jump targets, whose 12 bits bound a
    routine at 4096 instructions.
  - §23 #22, #4, #30, #35, #36, #38: reworded without release framing;
    #22 names the as-of reads that exist, #36 drops lazy seqs and cons
    cells (a cons is a list).
  - §10.4: the size-class pool allocator is deleted; the heap is
    backed by the process allocator (`docs/HEAP.md`).
  - §18: `nexis run` prints only what the program prints; `nexis
    test`, `nexis -e` and `nexis run -` exist (`docs/TOOLING.md`).
  - The stack guard: every native recursion on user-controlled depth
    checks the stack and raises the catchable `:stack-overflow`
    (`docs/VM.md` §13.1); the reader reports `:nesting-too-deep`.
  - The Nextomic store has twelve named trees: `nx/fulltext` joins the
    eleven of the 2026-09-18 index-layout entry (`docs/NEXTOMIC.md`
    §2).
  - `catch` also takes a class-name symbol or `:default`, which match
    every value as `any` does, so code written for Clojure runs.
  - PLAN.md is consolidated to the decisions: §0–§2, §6–§22, §26 and
    §27 move to the documents that own their facts (redirect table);
    §24 #1, #10, #11, #12 and §25 #9, #11, #14 are removed as settled;
    §24 #13 (`&form`, `&env`) is added.

- **2026-09-25 — Var-quote reader form (§28.2, §28.3).** `#'x` reads as
  the list `(var x)`, as in Clojure's reader, so Clojure code reads and
  a printed Var (`#'ns/name`) reads back. `docs/FORMS.md` §3 is the
  authority. §23 #33: a Var is callable, calling its value in force, as
  Clojure's `Var.invoke`, and `deref` of a Var reads the binding in
  force (`docs/VM.md` §6).

- **2026-09-25 — Serialization depth (§23 #25).** The codec walks
  containers with an explicit stack in both directions, so a
  serializable value nested to any depth encodes and decodes; the
  4096-level bound, which refused legitimate data and bought nothing
  the input-size bounds of decode do not, is gone
  (`docs/CODEC.md` §2.7).
