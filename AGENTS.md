# AGENTS.md — routing guide for contributors and AI sessions

Read `HANDOFF.md` first: what nexis and Nextomic are, how to verify the
tree, the architecture map, the contracts, what is proven, the known
gaps and the order of work. This file is the short index: what to read
in what order, the build steps, the authority order, the owner's rules
and the layout.

---

## What this project is

**nexis** is a Zig 0.16 Lisp with Clojure semantics on its own runtime
(reader, macroexpander, compiler, bytecode VM, persistent collections,
16-byte tagged value), durable refs backed by the emdb storage engine
(`db/*`), and **Nextomic**, a Datomic-class database in the same
binary: datoms in twelve emdb named trees, logical transaction numbers
in the history keys, Datalog `q`, `pull`, `as-of`/`since`/`history`,
speculative `with`. `bin/nexis run FILE.nx` and `bin/nexis repl` run
real programs and `bin/nexis disasm FILE.nx` shows their bytecode.
Zero changes to emdb.

---

## Required reading, in order

1. `HANDOFF.md` — the whole file; §2 to verify the tree before editing.
2. `PLAN.md` — §5 (three representations), §21 (roadmap), §23 (frozen
   decisions), the Amendment Log at the end, §24 (open questions),
   §28 / Appendix C (canonical Form schema). Budget an hour.
3. `docs/NEXTOMIC.md` — authoritative for `src/nextomic/` and the
   `nextomic` namespace. `../emdb/NEXTOMIC.md` §1 is the reader's
   introduction to Datomic; where the rest of that note describes
   Nextomic, `docs/NEXTOMIC.md` wins.
4. `CLOJURE-REVIEW.md` — what nexis takes, adapts and rejects from
   Clojure's source.
5. `docs/FORMS.md`, `docs/SEMANTICS.md`, `docs/COMPILER.md`,
   `docs/VM.md`, `docs/DB.md` — the per-layer contracts;
   `docs/TOOLING.md` the error report, disassembler, test runner,
   `pprint` and `math`; `docs/README.md` maps every module to its
   spec.
6. `ZIG-0.16.0.md` — mandatory before writing Zig.

---

## Build steps

- `zig build install` — `bin/nexis` (`run`, `repl`, `disasm`, `--help`) and
  `bin/nexis-golden`.
- `zig build quick` — the inner loop (seconds to a minute): the language
  binaries, the compile property tests, the eval-pipeline integration
  tests, the Nextomic unit and property binaries.
- `zig build nextomic-test` — Nextomic unit, property and corpus tests;
  `NEXTOMIC_BENCH=1` turns on the corpora's `[bench]` timing lines.
- `zig build nextomic-nx` — `test/nextomic/*.nx` through `bin/nexis`,
  diffed against the `.out` files.
- `zig build examples` — every `examples/*.nx` through `bin/nexis`; the
  store-backed ones twice.
- `zig build test --summary all` — everything (minutes). Before every
  commit. `HANDOFF.md` §2 carries the test count of record.
- `zig build golden` (`-Dupdate=true` rewrites), `zig build parser`
  (regenerates the committed `src/parser.zig` from `nexis.grammar`),
  `zig build bench` (ReleaseFast harness, `docs/BENCH.md`).

`-Doptimize=ReleaseFast` applies to any step. Two environment
variables: `NEXTOMIC_BENCH` (corpus timings) and `NEXIS_GC_STRESS`
(every VM collects every 4 KiB; `docs/GC.md` §7).

---

## Authority order

When sources disagree:

1. `PLAN.md` §23 frozen decisions; a change is a dated Amendment Log entry.
2. `PLAN.md` Appendix C (§28), the canonical Form schema.
3. `docs/*.md` — derivative; `docs/NEXTOMIC.md` is authoritative for the
   database. Fix a doc that conflicts with PLAN in the same commit.
4. Code comments — lowest. Code that disagrees with its spec is wrong.

Do not silently extend syntax, Form variants, serializable kinds or
value kinds; each is a frozen commitment. Amend first.
---

## The owner's rules

- **Zero changes to emdb.** Anything the engine seems to lack is solved
  on the nexis side (`docs/NEXTOMIC.md` §11 lists the two wishes and
  their workarounds; `../emdb/NEXTOMIC.md` §6 the temptations to refuse).
- **Timeless code and comments.** Describe what is; no era framing, no
  "now"/"previously"/"used to", no phase or turn numbers. Delete the old
  thing, do not narrate the transition. Dates live in amendment logs and
  commit messages only.
- **No AI attribution lines** in commits, pull requests or comments.
- **Every behaviour change starts with a failing test**; a Nextomic
  change also updates its `.out` and its `docs/NEXTOMIC.md` row.
- **The full gate before every commit.**
- **Spec first**: the governing section is written or amended in the
  same commit as the code.
- Commits: short imperative subject with an area prefix, a body citing
  the governing section, no attribution trailers; never `--amend` or
  force-push anything published. Work in a worktree per task; merge as a
  true merge and delete the branch.

---

## Layout

```
nexis/
├── HANDOFF.md, AGENTS.md, README.md, PLAN.md, CLOJURE-REVIEW.md, ZIG-0.16.0.md
├── build.zig, build.zig.zon     emdb is a path dependency (../emdb)
├── nexis.grammar                reader grammar (source of truth for src/parser.zig)
├── src/
│   ├── parser.zig               GENERATED — do not edit by hand
│   ├── reader.zig, expand.zig, compile.zig, vm.zig
│   ├── value.zig, heap.zig, gc.zig, pool.zig, intern.zig, hash.zig, eq.zig
│   ├── coll/                    champ, vector, list, transient
│   ├── string.zig, bignum.zig, codec.zig, format.zig, atom.zig, record.zig, protocol.zig, dispatch.zig
│   ├── db.zig                   emdb connection, durable refs, txn handles
│   ├── stdlib.zig, stdlib/*.nx  native tables; core, nextomic, test, pprint and math .nx embedded at build
│   ├── loader.zig, cli.zig, disasm.zig, bench.zig, golden.zig
│   └── nextomic/                key datom store idents schema transact excise fulltext db handle
│                                marshal relation pull natives query.zig query/{ir,parse,plan,exec,rules,natives}
├── docs/                        one spec per module; NEXTOMIC.md for the database
├── test/prop/ integration/ golden/ nextomic/
├── examples/                    working .nx programs (examples/README.md)
└── bin/                         build output
```

Stage boundaries are strict (PLAN §5, `docs/FORMS.md` §4): reader →
Form → expander → compiler → bytecode → VM; no stage peeks past the
next. Nextomic sits above `dispatch` and `vm`, is imported by `stdlib`
only, holds raw `*emdb.Txn` handles and byte keys, and shares only the
engine and the `:db/*` error names with the `db/*` layer.

## Traps

- Zig 0.16: `std.heap.DebugAllocator(.{})`, `std.Io.Dir.cwd()` with
  `io: std.Io` threaded through, `std.ArrayList(T)` is `.empty`.
- A source file cannot be both a test binary's root and a named import
  of the same graph: `dispatch` is a one-way terminal and
  `nextomic_handle` its own module for this reason.
- nexus: the number token must be named `integer`; identifier dispatch
  fires only for a token named `ident`; multi-char literals need `@op`.
- emdb's page size is fixed for a file's life; `db.zig` and
  `nextomic/store.zig` pin 16 KiB. Never open a store another way.
- A native's arguments are rooted for its call; a callback result it
  keeps across a further `vm.callValue` is not, and goes on a
  `vm.rootScope()` first (`docs/GC.md` §11.5). `NEXIS_GC_STRESS=1 zig
  build test` makes every rooting gap show. `zig fmt --check` the
  files you touch (only the generated `src/parser.zig` fails).

If any of this conflicts with what you believe the user wants, ask.
