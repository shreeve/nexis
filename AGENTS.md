# AGENTS.md — routing guide for contributors and AI sessions

Short version: read `PLAN.md` end-to-end before you do anything else,
then `HANDOFF.md` for the ranked next-work list.

---

## What this project is

**nexis** is a Zig-native Lisp with Clojure semantics, a first-class
durable identity model backed by `emdb`, and **Nextomic**, a
Datomic-class database (datoms in emdb named trees, logical
transaction numbers in the history keys, Datalog `q`, `pull`,
speculative `with`) in the same binary. See `PLAN.md` §0–§1 for the
pitch and `docs/NEXTOMIC.md` for the database.

Status: the language runs real programs end to end (`bin/nexis run`,
`bin/nexis repl`): reader, macroexpander, compiler, bytecode VM, host
and user macros, multi-namespace with `require`, destructuring and
multi-arity `defn`, doubles with Clojure contagion, keyword/map/set/
vector as functions, atoms, strings and I/O, records and protocols,
`case`/`condp`/`for`, durable refs with explicit transactions and
snapshots, and the `nextomic` namespace with `with-conn`. `zig build
test` runs 1265 tests across 111 steps. What does not exist is
listed under "Known gaps" in `README.md` and ranked in `HANDOFF.md`:
the collector is implemented but never invoked at runtime, bignum
arithmetic and `binding` are absent, and PLAN §21 Phase 5 as defined
(test runner, `nexis.test`/`math`/`pprint`, `--disasm`, source-mapped
stack traces) is open.

---

## Required reading (in order)

1. **`PLAN.md`** — the authoritative design. Budget 60–90 minutes. Especially:
   - §5 (three representations — non-negotiable boundary)
   - §21 (roadmap — which phase rows shipped, which are open)
   - §23 (hard decisions — frozen commitments; changing one requires an amendment)
   - the Amendment Log at the end of the file (every §23 change since v1.1, dated)
   - §24 (open questions — deliberately undecided)
   - §28 / Appendix C (canonical Form schema)
2. **`HANDOFF.md`** — what exists, how to verify it, the ranked next-work list.
3. **`CLOJURE-REVIEW.md`** — what we take, adapt, and reject from Clojure.
4. **`docs/NEXTOMIC.md`** — the v1 Datomic-class database on nexis +
   emdb: store layout, transactions, db-values and time, query
   pipeline, Lisp API, errors, module layout. Binding for anything
   under `src/nextomic/`.
5. **`docs/FORMS.md`** — Appendix C lifted into a standalone contract plus
   the pretty-printer spec and stage-ownership table.
6. **`docs/SEMANTICS.md`** — equality/hash/numeric spec (frozen; §2 carries
   the number-tower contagion rules).
7. **`docs/COMPILER.md`** and **`docs/VM.md`** — the compiler and runtime
   contracts, each with its own amendment log.
8. **`docs/DB.md`** — the `db/*` key-value layer and the emdb seam
   (page size pin, tree-id cache, `:db/*` error names).
9. **`ZIG-0.16.0.md`** — mandatory before writing any Zig. 30+ stdlib
   APIs changed between 0.15 and 0.16 in ways that silently break
   training-data code.

`docs/README.md` maps every module to its spec.

---

## Authority order

When these sources disagree:

1. `PLAN.md` §23 frozen decisions — highest authority.
2. `PLAN.md` Appendix C (§28) canonical schema.
3. `docs/FORMS.md`, `docs/SEMANTICS.md`, `docs/CODEC.md` — derivative; must
   track PLAN.md. If a conflict arises, fix the doc in the same commit.
4. Code comments — lowest. If code says one thing and PLAN.md says another,
   PLAN.md wins and the code is wrong.

Do **not** silently extend syntax, Form variants, serializable kinds, or
value kinds. Each of these is a frozen commitment. Amend `PLAN.md` first.

---

## Build steps

- `zig build install` — `bin/nexis` (CLI: `run`, `repl`) and `bin/nexis-golden`.
- `zig build phase2-test` — the inner loop, seconds: atom, record,
  protocol, vm, format, compile, expand, stdlib and loader module
  tests, the compile property tests, the eval-pipeline integration
  tests, and the Nextomic unit, key and transaction property tests.
- `zig build nextomic-test` — only Nextomic: `src/nextomic/` unit tests,
  `test/prop/nextomic_key.zig`, `test/prop/nextomic_tx.zig`, and the
  query and pull corpora in `test/integration/nextomic_{q,pull}.zig`
  (each corpus ends with a benchmark that prints `[bench]` lines to
  stderr; the build runner echoes them under "failed command" even
  when the step passes — read the summary line).
- `zig build nextomic-nx` — runs `test/nextomic/*.nx` through `bin/nexis`
  in a scratch directory, in order, and diffs stdout against the `.out`
  files. `persist-1` and `persist-2` share one store across two
  processes.
- `zig build test --summary all` — everything above plus the reader
  goldens and the Phase 1 randomized property gates (~100k HAMT ops;
  peaks near 1 GB, minutes). Run before commits, not in the inner loop.
- `zig build golden` — reader golden diff alone;
  `zig build golden -Dupdate=true` rewrites expected files in place (use
  only when intentionally changing the schema; commit the diffs together).
- `zig build parser` — regenerates `src/parser.zig` from `nexis.grammar`
  by invoking `../nexus/bin/nexus` (the nexus binary must exist).
- `zig build bench` — the ReleaseFast benchmark harness (`docs/BENCH.md`);
  `-- --out bench/baseline.json` writes the machine-readable run.

There are no environment variables: every switch is a build option or
a CLI argument. The generated `src/parser.zig` **is** committed — it is
the authoritative artifact for consumers. Regenerate it whenever you
edit `nexis.grammar`.

---

## Repository layout

```
nexis/
├── PLAN.md                      authoritative design + amendment log
├── HANDOFF.md                   state + ranked next work
├── AGENTS.md                    this file
├── CLOJURE-REVIEW.md
├── ZIG-0.16.0.md
├── README.md
├── build.zig, build.zig.zon     emdb is a path dependency
├── nexis.grammar                reader grammar (source of truth)
├── src/
│   ├── nexis.zig                @lang module: Tag enum + Lexer wrapper
│   ├── parser.zig               GENERATED — do not edit by hand
│   ├── reader.zig               Sexp → Form normalizer + pretty-printer
│   ├── expand.zig               macroexpander, syntax-quote, user macros
│   ├── compile.zig              Form → Tiny IR → bytecode
│   ├── vm.zig                   bytecode VM, frames, handlers, callValue
│   ├── value.zig, heap.zig, gc.zig, pool.zig, intern.zig, hash.zig, eq.zig
│   ├── coll/                    champ, vector, list, transient
│   ├── string.zig, bignum.zig, codec.zig, format.zig
│   ├── atom.zig, record.zig, protocol.zig, dispatch.zig
│   ├── db.zig                   emdb connection, durable refs, txn handles
│   ├── stdlib.zig               native fn tables; embeds src/stdlib/*.nx
│   ├── stdlib/core.nx           macros + fns written in nexis
│   ├── stdlib/nextomic.nx       with-conn
│   ├── loader.zig, cli.zig, bench.zig, golden.zig
│   └── nextomic/
│       ├── root.zig             module root
│       ├── key.zig, datom.zig, store.zig, idents.zig, schema.zig
│       ├── transact.zig, db.zig, relation.zig, pull.zig
│       ├── query/{ir,parse,plan,exec,rules,natives}.zig
│       ├── natives.zig          nextomic/* NativeFn table, error mapping
│       └── handle.zig           heap bodies of nextomic_conn / nextomic_db
├── docs/                        one spec per module; NEXTOMIC.md for the database
├── test/
│   ├── prop/                    property tests (incl. nextomic_key, nextomic_tx)
│   ├── integration/             eval_pipeline, nextomic_q, nextomic_pull corpora
│   ├── golden/                  reader goldens
│   └── nextomic/                *.nx end-to-end scripts + *.out
├── examples/                    working .nx programs (examples/README.md)
├── bench/main.zig               benchmark driver
└── bin/                         build output
```

---

## Stage boundaries (strict — `PLAN.md` §11.2, FORMS.md §4)

```
source.nx
   │
   ▼   nexus-generated src/parser.zig
raw Sexp tree
   │
   ▼   src/reader.zig     (normalize, merge meta, lower #(), drop #_)
canonical Form tree
   │
   ▼   src/expand.zig     (syntax-quote, host + user macros, namespaces)
expanded Form
   │
   ▼   src/compile.zig    (lower to Tiny IR, then emit bytecode)
bytecode
   │
   ▼   src/vm.zig
```

Violating a stage boundary is how language projects turn into tar pits
(`PLAN.md` §5). If you find yourself wanting to peek past the current stage
because it's convenient, stop.

Nextomic sits above `dispatch` and `vm` and is imported by `stdlib` only.
It holds raw `*emdb.Txn` handles and byte keys and never goes through the
`db/*` codec path; the two layers share the engine and the `:db/*` error
keywords and nothing else (`docs/DB.md` §11.1).

---

## Common traps (save yourself time)

- `std.heap.GeneralPurposeAllocator` is **gone** in 0.16.0. Use
  `std.heap.DebugAllocator(.{})` or the `init.gpa` from `pub fn main(init:
  std.process.Init)`. See `ZIG-0.16.0.md`.
- `std.fs.cwd()` → `std.Io.Dir.cwd()`; most FS ops take `io: std.Io`.
- `std.io.Writer.fixed` → `std.Io.Writer.fixed`. `std.io.fixedBufferStream`
  is gone.
- **Nexus-specific:** the token name `integer` is hardcoded inside the
  generated scanner. Name your number token `integer`, not `int`. Likewise,
  nexus only emits the `isLetter → scanIdent` dispatch when your token is
  named `ident`; use `IDENT` in parser rules and wrap it into whatever
  semantic tag you want via the action template.
- **Multi-char literals** in grammar rules (e.g. `"~@"`, `"#{"`) are **not**
  auto-mapped to their tokens. Add an `@op` directive.
- **Build-graph self-collision**: a source file cannot be both a test
  binary's root and a named import of the same graph; `dispatch` is a
  one-way terminal for this reason, and `nextomic_handle` is its own
  module below `dispatch`/`format`/`gc` for the same reason.
- **emdb page size is fixed for a file's life.** `db.zig` and
  `nextomic/store.zig` open every store with `pageSize = 16384`; the
  Linux engine default is 4 KiB, so never open a nexis store through a
  path that omits the option.
- **Native functions must not hold VM-heap pointers across a call back
  into the VM** unless they root them; the collector is not wired, so
  this is latent rather than fatal, but it is the rule the GC wiring
  in `HANDOFF.md` depends on.

---

## Session workflow for contributors / AI sessions

1. `zig build test --summary all` before your first edit. If the tree
   doesn't build clean, stop and fix the environment first.
2. Make the smallest change that actually addresses the task.
3. If you touch `nexis.grammar`, `src/nexis.zig`, or `src/reader.zig`:
   regenerate the parser and re-run goldens. If a golden changed
   semantically, update it with `-Dupdate=true` and inspect the diff in
   your commit.
4. If you touch `src/nextomic/`: run `zig build nextomic-test` and
   `zig build nextomic-nx`; a behavior change updates the matching
   `test/nextomic/*.out` and the row in `docs/NEXTOMIC.md` §6 or §7 in
   the same commit.
5. If you touch documentation, cite the PLAN.md section that grounds your
   change. A §23 decision changes only through a dated Amendment Log entry.
6. Write Zig tests inline in the module you edited. Don't add a new test
   file unless scoping truly demands it.
7. Wording is timeless: describe what is, not what was or when it changed.
   Dates belong in amendment logs and commit messages only.

---

## Non-negotiable discipline (from `PLAN.md` §"Start here")

1. **Do not break the three-representations boundary** (§5). Form, Value,
   Durable Encoded are distinct. They only fuse through explicit codec ops.
2. **Respect SCVU operand-kind encoding** (§12.2).
3. **Do not widen the v1 non-goals list** (§4) without an amendment.
4. **Do not expose benchmarks publicly** until they satisfy `docs/BENCH.md`
   (numerical, accurate, fair, relevant). The plan intentionally
   under-promises and over-delivers.
5. **Zero changes to emdb.** Nextomic is built on the engine as it is;
   anything the engine seems to lack is solved on the nexis side
   (`docs/NEXTOMIC.md` §11).

If any of this conflicts with what you believe the user wants, **ask**.
Do not silently deviate from frozen decisions.
