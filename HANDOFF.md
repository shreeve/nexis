# HANDOFF.md — state of nexis and the ranked next work

Self-contained. Everything a new session needs is in this repository
and its sibling `../emdb`; no external conversation, tool, or
transcript is a prerequisite. Read `AGENTS.md` for routing and
`PLAN.md` for the design before acting on anything here.

---

## 1. What exists

**nexis** is a Zig 0.16 Lisp with Clojure semantics on the emdb storage
engine, plus **Nextomic**, a Datomic-class database in the same binary.
`bin/nexis run FILE.nx` and `bin/nexis repl` run real programs.

Language and runtime (`src/`):

- Reader: nexus-generated parser, canonical Form schema, pretty-printer,
  goldens (`docs/FORMS.md`).
- Values: 16-byte tagged Value; CHAMP map/set, 32-way persistent
  vector, list, transients; 48-bit fixnum and f64 with Clojure
  contagion (`(= 1 1.0)` false, `(== 1 1.0)` true, inexact integer
  `/` yields a float, `:divide-by-zero` and `:arithmetic-overflow`
  catchable); a `bignum` kind with codec and hashing but no
  arithmetic; strings; atoms; records; protocols.
- Compiler and VM: Form → Tiny IR → 64-bit bytecode; slot VM with
  closures, `recur`, `letfn*`, try/catch/finally, catchable VM errors as
  keywords, reentrant `VM.callValue`, `VM.throwValue`/`VM.throwKeyword`
  for native code. Every frame records its entry stack length and
  restores it on return and unwind, so nested calls through native
  functions keep the stack invariant. A symbol that names nothing is
  `UnresolvedSymbol` at its own source span.
- Macros and namespaces: host macros, user `defmacro` in a compile-time
  sub-VM, syntax-quote with auto-gensym, qualified macro heads,
  namespaced keywords, `(ns ...)`, `require` with `:as`, file loading.
- Core library: 162 native functions in `src/stdlib.zig`, 44 macros and
  functions in `src/stdlib/core.nx`, `nexis.string`; keyword, map, set
  and vector are invocable.
- Durable refs (`db/*`): emdb named trees, explicit `with-tx`/
  `with-read-tx`, `@deref`, `db/alter!`, `db/scan`, `db/reduce-tree`,
  snapshots. Seam guarantees: page size pinned to 16 KiB and 128 named
  trees, one release of the path when emdb refuses to open, tree ids
  resolved once per connection, cursor natives read whole values,
  every engine failure a named `:db/*` keyword (`docs/DB.md`).

Nextomic (`src/nextomic/`, spec `docs/NEXTOMIC.md`):

- Eleven emdb named trees: four current indexes (`nx/eavt`, `nx/aevt`,
  `nx/avet`, `nx/vaet`), four history indexes with the logical
  transaction `t` in the key, `nx/txlog`, `nx/idents`, `nx/sys`.
- Modules: `key` (sortable encodings), `datom`, `store`, `idents`,
  `schema`, `transact`, `db` (db-values, fold, entity, tx-range),
  `relation` (columnar), `query/{ir,parse,plan,exec,rules,natives}`,
  `pull`, `natives`, `handle` (the `nextomic_conn` / `nextomic_db` kinds).
- Natives: `connect release db basis-t transact! entity entid ident
  datoms as-of since history tx-range schema sync q explain pull
  pull-many with`; `with-conn` in `src/stdlib/nextomic.nx`. `q` is a
  native over a query value, cached per VM by value.
- Errors (§7): a Nextomic-semantic error is a map whose `:error` is a
  `:nextomic/*` keyword and whose other keys carry the context
  (`{:error :nextomic/unique :attr ... :value ...}`); an argument of
  the wrong shape is the VM's `:kind-mismatch` / `:invalid-argument` /
  `:arity-mismatch`; an engine failure is a `:db/*` keyword. All are
  catchable by `try`.
- Memory: every Nextomic operation allocates in its own arena and
  copies only results into the VM heap; the tx-data, reports and
  results a program holds stay in the VM heap, where nothing is
  collected.
- Zero changes to emdb.

Tests: `zig build test --summary all` runs **1282 tests across 135
steps**: inline unit tests, `test/prop/*` (including `nextomic_key`,
`nextomic_tx`), the query and pull corpora in `test/integration/`
against naive evaluators, reader goldens, `test/nextomic/*.nx`
end-to-end scripts diffed against `.out` files, and every
`examples/*.nx` through `bin/nexis` (the store-backed ones twice).

Examples: `examples/nextomic-app.nx` (clinic chart: schema, upserts,
components, `q`, `pull`, time views, `with`, a caught
`:nextomic/unique`), `examples/todo-app.nx` (durable refs across
processes), `examples/shapes-app.nx` (multi-file protocols + records +
atoms). See `examples/README.md`.

---

## 2. Verify on arrival

```bash
cd /path/to/nexis                       # ../emdb must be a sibling
git status                              # clean main
zig build install
zig build test --summary all            # expect 1282/1282 tests, 135/135 steps
./bin/nexis run examples/nextomic-app.nx
./bin/nexis run examples/nextomic-app.nx   # second run: same store, upserts, no new patients
./bin/nexis run examples/todo-app.nx
./bin/nexis run examples/todo-app.nx       # second run shows :completed 1
./bin/nexis run examples/shapes-app.nx     # "total-area atom = 9650", every satisfies?=true
```

Loops: `zig build quick` (seconds) for language work,
`zig build nextomic-test` + `zig build nextomic-nx` for Nextomic,
`zig build examples` after touching anything an example uses, the
full suite before every commit. The two corpus binaries end with a
benchmark whose row-count checks always run; its `[bench]` timing
lines print only when the `NEXTOMIC_BENCH` environment variable is
set, and Debug-build numbers under the testing allocator are not
performance measurements (`docs/PERF.md` §3.7 has the ReleaseFast
ones).

---

## 3. Known gaps (do not rediscover)

| Gap | Where it shows |
|---|---|
| Collector never invoked at runtime | `src/gc.zig` `collect` has no caller; process memory grows without bound, so a loader that transacts millions of datoms batches the work across processes |
| No bignum arithmetic | overflow raises `:arithmetic-overflow`; an integer literal outside ±2^47 is `IntegerOutOfFixnumRange` at compile time |
| No `^:dynamic` / `binding` | `(binding ...)` is `UnresolvedSymbol` |
| PLAN §21 Phase 5 as defined | no test runner, `nexis.test`/`math`/`pprint`, `--disasm`; runtime errors carry no source spans |
| `(vec #{...})`, `(vec {...})` | `:kind-mismatch`; `vec` takes nil, vector, list |
| Datalog function-position variables | function position takes a symbol, never a `?var` (`docs/NEXTOMIC.md` §5) |
| `typed_vector` | reserved kind, no implementation, no `nexis.simd` |
| Records, protocols, functions, vars, transients, namespaces, tx handles | `:unserializable` |
| CLI usage text | `src/cli.zig` `--help` describes the Phase 2 surface only |

---

## 4. Ranked next work

Each item is self-contained; take them in order unless a user need
reorders them. Spec first (the governing doc section), then code with
inline tests, then `zig build test` green, then commit.

1. **Bignum arithmetic and promotion.** `src/bignum.zig` holds the
   kind; `docs/BIGNUM.md` the layout. Wire `+ - * quot rem inc dec`
   and comparisons to promote on fixnum overflow instead of raising
   `:arithmetic-overflow`, canonicalize results that fit back to
   fixnum (BIGNUM.md's canonicalization invariant), lift out-of-range
   integer literals in `src/compile.zig` (the `IntegerOutOfFixnumRange`
   site), keep contagion with f64. Update SEMANTICS.md §2 and the
   PLAN Amendment Log entry on the number tower.
2. **GC wiring with a native-function rooting protocol.** Define
   roots: VM stack and frames, namespace Vars, the interner, atom
   cells, open `db`/`nextomic` handles, the Nextomic query and rule
   caches (`docs/NEXTOMIC.md` §5 says a collector that frees or moves
   values must clear both caches), and a scoped root set that native
   functions push values onto before calling back into the VM
   (`callValue`). Trigger from the allocator on a byte threshold.
   `docs/GC.md` is the spec; `test/prop/gc.zig` the gate. Nextomic
   is arena-scoped and needs no changes beyond cache clearing.
3. **Clojure surface gaps.** Core forms and functions a Clojure
   programmer reaches for that are absent or diverge; each is a
   small, self-contained change in `src/expand.zig`, `src/compile.zig`
   or `src/stdlib.zig` + `core.nx`:
   - `case` evaluates its keys: `(case 1 (1 2) :a :d)` fails; keys
     must be constants and a list key an alternative set.
   - Syntax-quote: `~@` of a vector or nil, quoted maps, sets and
     vectors with `~@`, nested `#()` outside macro arguments, and
     symbol qualification (PLAN §23 #29 promises it; the expander
     leaves symbols bare).
   - Multi-arity anonymous `fn` (`defn` has it; `fn` and `letfn` do
     not).
   - `try` without `catch` (finally-only) is `MalformedForm`.
   - Empty-body `fn`/`defn`/`let` and the literal `()` are compile
     errors where Clojure yields nil / `()`.
   - `defn` docstrings, attribute maps and `^:private`.
   - Destructuring `:strs`/`:syms`, namespaced `:keys`, keyword
     arguments (`& {:keys [...]}`), and `loop` bindings.
   - `doseq` `:when`/`:let`/`:while`.
   - `int`/`long`/`double` conversions (no way to turn a double into
     an integer).
   - `meta`/`with-meta`, `ex-info`/`ex-data`, `macroexpand`,
     `read-string`, `list*`, `reduced`.
   - Reader errors carry no file, line or column.
4. **Phase 5 as PLAN §21 defines it.** A test runner and `nexis.test`
   (`deftest`/`is`/`run-tests`), `nexis.math`, `nexis.pprint`,
   `nexis --disasm`, and source-mapped runtime errors (a PC → span
   table per Routine; `docs/COMPILER.md` and `docs/VM.md` amendment
   logs). Refresh the `src/cli.zig` usage text in the same pass.
5. **Datalog function-position variables.** Allow `[(?f ?x) ?y]` and
   `[(?pred ?x)]` where `?f` is bound to a function value by an `:in`
   input or an earlier clause; `query/parse.zig` accepts a
   symbol only, `query/exec.zig` calls through the CallHook. Add
   corpus cases in `test/integration/nextomic_q.zig` and a row in
   `docs/NEXTOMIC.md` §5.
6. **`typed_vector`.** PLAN §8 reserves the kind and PLAN §15.11
   NX-2 expects Relation columns to share its representation. Ship
   the kind (i64/f64 columns), codec arms, and `vec`/`nth`/`count`
   over it before any `nexis.simd` kernel.
7. **`^:dynamic` Vars and `binding`.** PLAN §21 Phase 3.7. A dynamic
   binding stack on the VM, `binding` as a macro over push/pop with a
   `finally`, Var loads checking the stack only for Vars marked
   dynamic so ordinary Var loads stay a single indirection.
8. **`vec` over sets and maps.** Add `.persistent_set` and
   `.persistent_map` arms to `fnVec` in `src/stdlib.zig` (map →
   `[k v]` pairs).
9. **Nextomic follow-ups**, in the order they unblock users:
   - Transaction functions and `:db.fn/cas` (a Lisp function called
     inside `transact!` with `db-before` and returning tx-data; needs
     item 2's rooting rule when the function allocates).
   - Excision (remove datoms from history; listed in `docs/NEXTOMIC.md` §6).
   - Full-text (`:db/fulltext` attribute flag; a tokens tree).
   - Lazy entities (an `entity` that reads attributes on access).
   - Hash-join tuning: the planner's estimates come from tree counts;
     measure `test/integration/nextomic_q.zig`'s three-way joins in
     ReleaseFast before and after any change (`docs/PERF.md` §3.7).
   - Linux 4K-page CI run: the page size is pinned to 16 KiB in code,
     so a Linux run should produce byte-identical stores; add it to
     CI to prove the pin holds where the engine default differs.
10. **Performance pass** (PLAN §21 Phase 6, `docs/PERF.md` §6): inline
   caches on Var loads, SIMD CHAMP nodes, zero-copy strings from emdb
   pages. Measure first with `zig build bench`; `docs/BENCH.md` is the
   honesty gate.

---

## 5. Architecture you must not reshape

These interfaces are settled; new work builds on them:

- **Three representations** (PLAN §5): Form, Value, Encoded fuse only
  through the codec.
- **Value model**: 16-byte tagged Value, `Kind` enum (heap kinds up to
  `nextomic_db = 39`). New kinds add to the enum and need dispatch,
  format and gc arms; `nextomic_handle` shows the pattern for a kind
  whose body lives above `dispatch`.
- **dispatch is a one-way terminal**: nothing below it imports it.
- **Equality-category hash domains**: cross-type sequential equality
  (list = vector) holds by construction; map and set are their own
  categories; keyword and symbol hash domains are separated.
- **VM**: group-based opcode dispatch, `entry_stack_len` per frame,
  handler and finally stacks, `callValue` reentrancy, range-call ABI.
- **Compiler**: `lowerForm` → Tiny → emitter; capture analysis is a
  pre-pass, not lazy boxing; Vars are heap-allocated identity-stable
  cells and global calls go through Var indirection (PLAN §23 #20).
- **Expander**: per-form-rule walker, syntax-quote, host + user
  macros, compile-eval callback, namespace and load callbacks.
- **db seam**: `db.Connection` owns the `Env`; Nextomic borrows the
  `Env` and holds raw `*emdb.Txn` handles and byte keys; the two
  layers share only the engine and the `:db/*` error names.
- **Nextomic commitments** (`docs/NEXTOMIC.md` §1): bytes-only keys,
  current and history trees separate, logical `t`, db-value as a
  plain value with no open read transaction, integer entity ids in
  partitions, schema as datoms, `q` a native, arena per operation.
- **Zero changes to emdb.**

---

## 6. Discipline

- Spec first for anything substantive: the governing doc section is
  written or amended before the code, in the same commit.
- A PLAN §23 decision changes only through a dated Amendment Log entry
  at the end of `PLAN.md`. Per-doc amendment logs (COMPILER.md, VM.md,
  ATOM.md, PROTOCOLS.md, PERF.md) record the downstream detail.
- Hand-trace before code for anything touching the Value model,
  `call:call` dispatch, or the GC integration.
- Inline `test` blocks for structural invariants; `test/prop/*.zig`
  with deterministic seeds for statistical laws; every Nextomic
  behavior change updates a `test/nextomic/*.out`.
- Read the actual Clojure source and the actual Zig 0.16 stdlib
  before asserting what either does; `CLOJURE-REVIEW.md` records what
  the Clojure source settled, `ZIG-0.16.0.md` the APIs that differ
  from training data.
- Timeless wording in code and docs: describe what is. Dates live in
  amendment logs and commit messages only.
- Commits: short imperative subject, substantive body citing the
  governing sections, split along logical lines, no attribution
  trailers, never `--amend` or force-push anything published.
- Performance claims only from `zig build bench` in ReleaseFast under
  `docs/BENCH.md`'s rules; publish where Clojure wins too.

---

## 7. Zig 0.16 gotchas that have bitten this tree

- `std.ArrayList(T){}` → `.empty`; `std.heap.GeneralPurposeAllocator`
  → `std.heap.DebugAllocator(.{})`; `std.fs.cwd()` → `std.Io.Dir.cwd()`
  with `io: std.Io` threaded through.
- `std.io.Writer.Allocating`: `.writer` is a field, not a method.
- `@intCast(v)` infers its target; `@ptrCast` needs `@alignCast` when
  the target alignment is larger (heap headers are `align(16)`).
- `std.math.add`/`mul` for checked arithmetic; `std.hash.XxHash3`.
- Unused locals must be `const`.
- A source file cannot be both a test binary's root and a named import
  of the same graph (why `dispatch` is a terminal and `nextomic_handle`
  is its own module).
- Packed structs have field-order layout; `vm.Inst`/`vm.Operand`
  depend on it.
- nexus: the number token must be named `integer`; identifier dispatch
  fires only for a token named `ident`; multi-char literals need `@op`.
- emdb: page size is fixed for a file's life; always open through
  `db.zig`/`nextomic/store.zig`, which pin 16 KiB.
