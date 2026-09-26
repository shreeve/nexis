# AGENTS.md — routing guide for contributors and AI sessions

This file owns the reading order, the build steps, the authority order,
the owner's rules, the layout and the traps. `HANDOFF.md` is the state
of the tree: how to verify it, the architecture map, what is proven,
the known gaps and the order of work.

---

## What this project is

**nexis** is a Zig 0.16 Lisp with Clojure semantics on its own runtime
(reader, macroexpander, compiler, bytecode VM, persistent collections,
16-byte tagged value, precise GC), durable refs backed by the emdb
storage engine (`db/*`), and **Nextomic**, a Datomic-class database in
the same binary: datoms in twelve emdb named trees, logical
transaction numbers in the history keys, Datalog `q`, `pull`,
`as-of`/`since`/`history`, speculative `with`. `bin/nexis run FILE.nx`,
`bin/nexis repl`, `bin/nexis test FILE` and `bin/nexis -e EXPR` run
real programs; `bin/nexis disasm FILE.nx` shows their bytecode. Zero
changes to emdb.

---

## Required reading, in order

1. `HANDOFF.md`: the whole file; §2 to verify the tree before editing.
2. `PLAN.md`: §3 principles, §4 non-goals, §5 the three
   representations, §23 frozen decisions, §24 open questions, §28 the
   canonical Form schema, and the Amendment Log. Its redirect table
   maps an old "PLAN §N" citation to the document that owns it now.
3. The spec of the module you touch: `docs/README.md` maps each source
   file to its spec. `docs/NEXTOMIC.md` is authoritative for
   `src/nextomic/` and the `nextomic` namespace (`../emdb/NEXTOMIC.md`
   §1 is the reader's introduction to Datomic; where the rest of that
   note describes Nextomic, `docs/NEXTOMIC.md` wins).
4. `CLOJURE-REVIEW.md`: what nexis takes, adapts and rejects from
   Clojure, and where it differs.
5. `ZIG-0.16.0.md` before writing Zig: the idioms and traps of this
   tree.

---

## Build steps

| Step | What it runs |
|---|---|
| `zig build install` | `bin/nexis` and `bin/nexis-golden` |
| `zig build quick` | the inner loop: the `unit` binary (every inline test in `src/`), the compile and Nextomic property tests, the `eval_pipeline`, `runtime_polish` and `numbers` integration tests |
| `zig build nextomic-test` | the Nextomic unit tests, `test/prop/nextomic_{key,tx}.zig`, the Nextomic integration corpora |
| `zig build nextomic-nx` | every `test/nextomic/*.nx` through `bin/nexis` from a fresh directory, stdout diffed against its `.out` |
| `zig build examples` | every `examples/*.nx` through `bin/nexis`, stdout diffed against `test/examples/<name>.out`; those with a `.2.out` run twice |
| `zig build golden` | the reader goldens and the CLI goldens (`test/golden/cli`: error reports, a disassembly, script output, a REPL session, a byte-order-mark source, `--help` and the usage errors, each stream and exit code) |
| `zig build test --summary all` | the gate, 159 steps, about a minute from a warm cache: all of the above, every property test, the layering check and a compile check of `bench/` |
| `zig build bench [-- --filter nextomic]` | the ReleaseFast benchmark harness (`bench/`, `docs/BENCH.md`); `--filter` takes the categories `bench/main.zig` lists |
| `zig build parser` | regenerates `src/parser.zig` from `nexis.grammar` with `../nexus/bin/nexus` |

- `-Dupdate=true` on `test`, `golden`, `examples` or `nextomic-nx`
  rewrites every expected-output file the step compares; read the diff
  before committing it.
- `-Doptimize=ReleaseFast` applies to any step. A Debug binary is not
  a performance measurement.
- `NEXIS_GC_STRESS=1` makes every VM collect every 4 KiB of
  allocation (`docs/GC.md` §7); `NEXIS_GC_STRESS=1 zig build test`
  proves the natives' rooting. It is the only environment variable.
- `HANDOFF.md` §2 carries the gate's test count of record.

---

## Authority order

When sources disagree:

1. `PLAN.md` §23, the frozen decisions. A change is a dated Amendment
   Log entry, and the same commit rewrites the §23 text and every
   document it supersedes.
2. `PLAN.md` §28 (Appendix C), the canonical Form schema.
3. `docs/*.md`, one owner per fact; `docs/NEXTOMIC.md` is authoritative
   for the database.
4. Code comments.

Code and its spec must agree. A mismatch is a bug, fixed in one commit
on whichever side is wrong, with a test that pins the behaviour.
Do not silently extend syntax, Form variants, serializable kinds or
value kinds; each is a frozen commitment. Amend first.

---

## The owner's rules

- **Zero changes to emdb.** Anything the engine seems to lack is solved
  on the nexis side (`docs/NEXTOMIC.md` §11; `../emdb/NEXTOMIC.md` §6
  lists the temptations to refuse).
- **Timeless code, comments and docs.** Describe what is; no era
  framing, no "now"/"previously"/"used to", no phase or turn numbers.
  Delete the old thing, do not narrate the transition. Dates live in
  the Amendment Log, `docs/PERF.md`'s provenance table and commit
  messages only.
- **No AI attribution** in commits, pull requests, comments or docs.
- **Every behaviour change starts with a failing test**: an inline
  `test` block, a `test/prop` sweep, a corpus case, or a `.nx` script
  and its `.out`. A Nextomic change also updates its `.out` and its
  `docs/NEXTOMIC.md` row.
- **The full gate before every commit.**
- **Spec first**: the governing section is written or amended in the
  same commit as the code.
- **Read the source before asserting**: the installed Zig 0.16 stdlib
  for Zig, Clojure 1.12 (`CLOJURE-REVIEW.md` cites it by tag) for
  Clojure.
- **Performance claims** are ReleaseFast numbers from
  `zig build bench`; a comparison with Clojure follows `docs/BENCH.md`.
- **Commits**: a short imperative subject with an area prefix
  (`vm:`, `nextomic:`, `docs:`, ...), a body citing the governing
  section, no attribution trailers; never `--amend` or force-push
  anything published. Work in a worktree per task
  (`git worktree add ../nexis-wt-<name> -b <name>`; `../emdb` resolves
  from a sibling); merge as a true merge and delete the branch.

---

## Layout

```
nexis/
├── AGENTS.md HANDOFF.md README.md PLAN.md CLOJURE-REVIEW.md ZIG-0.16.0.md
├── build.zig, build.zig.zon     emdb is a path dependency (../emdb)
├── nexis.grammar                reader grammar (source of truth for src/parser.zig)
├── src/
│   ├── root.zig                 the `nexis` module: declares every runtime file, bottom-up
│   ├── stack.zig                the native stack guard
│   ├── parser.zig               GENERATED by nexus; do not edit by hand
│   ├── nexis.zig                the scanner and the Sexp tag set the parser drives
│   ├── reader.zig expand.zig compile.zig vm.zig
│   ├── value.zig heap.zig gc.zig intern.zig hash.zig dispatch.zig
│   ├── coll/                    champ vector list transient typed_vector
│   ├── string.zig bignum.zig codec.zig format.zig atom.zig record.zig protocol.zig
│   ├── db.zig                   emdb connections, durable refs, transaction handles
│   ├── stdlib.zig, stdlib/*.nx  native tables; core nextomic test pprint math string set .nx embedded at build
│   ├── loader.zig disasm.zig bench.zig
│   ├── cli.zig golden.zig       the two executable roots
│   └── nextomic/                root key datom store idents schema transact excise fulltext db handle
│                                marshal relation pull natives query.zig query/{ir,parse,plan,exec,rules,natives}
├── docs/                        one spec per module (docs/README.md maps them)
├── test/
│   ├── harness.zig              the pipeline harness the property and integration tests share
│   ├── prop/ integration/       property sweeps; end-to-end suites and Nextomic corpora
│   ├── golden/                  reader goldens, reader-error cases, CLI goldens
│   ├── nextomic/                end-to-end .nx scripts and their .out
│   └── examples/                the pinned output of every examples/*.nx
├── examples/                    working .nx programs (examples/README.md)
├── bench/                       main.zig (the harness), nextomic.zig (its Nextomic scenarios)
└── bin/                         build output
```

The runtime is one Zig module rooted at `src/root.zig`, whose files
import each other by relative path. `src/root.zig` declares them
bottom-up, and a file may import only files declared above it: that
keeps the stages in order (reader → Form → expander → compiler →
bytecode → VM; PLAN §5), with the VM, dispatch and the value layer
below all three. `parser.zig` and `nexis.zig` belong to `reader.zig`;
every file under `src/nextomic/` except `handle.zig` belongs to
`nextomic/root.zig`, which only `stdlib.zig` imports. Nextomic sits
above `dispatch` and `vm`, holds raw `*emdb.Txn` handles and byte
keys, opens its own emdb `Env` with the same pinned geometry, and
shares only the `:db/*` error names with the `db/*` layer. `build.zig`
`checkLayering` enforces all of this in `quick` and `test`.

---

## Traps

- **The native stack.** Every Zig function that recurses on
  user-controlled depth (reading, expanding, lowering, `=`, `hash`,
  compare, printing, the codec, pull, transaction expansion, query
  parsing, rule expansion, a native re-entering the VM) calls
  `try stack.check()` on entry and maps `error.StackOverflow` to the
  catchable `:stack-overflow` (`docs/VM.md` §13.1). A deep input must
  never segfault.
- **Rooting.** A native's arguments are rooted for its call; a value it
  keeps across a further `vm.callValue`, or across any allocation that
  can reach the safe point, is not, and goes on a `vm.rootScope()`
  first. That includes values the native built itself, such as a
  map-entry vector from an iterator (`docs/GC.md` §11.5).
  `NEXIS_GC_STRESS=1 zig build test` makes every rooting gap show.
- **Layering.** A new file under `src/` is declared in `src/root.zig`
  (its tests run only then) and imports only what is declared above
  it; the build rejects anything else.
- **The parser.** `src/parser.zig` is generated by nexus 1.0 from
  `nexis.grammar`; token names carry no behaviour, and the scanner is
  hand-written in `src/nexis.zig`, which replaces the generated lexer.
  Edit the grammar or the scanner, run `zig build parser`, and commit
  the regenerated file with them.
- **The page size.** emdb's page size is fixed for a file's life;
  `db.zig` and `nextomic/store.zig` pin 16 KiB. Never open a store
  another way.
- **Zig 0.16.** `init.gpa` is a `DebugAllocator` in Debug;
  `std.ArrayList(T)` is unmanaged and starts `.empty`; every file
  operation takes `io` (`ZIG-0.16.0.md`).
- **Formatting.** `zig fmt --check` the files you touch; only the
  generated `src/parser.zig` fails.

If any of this conflicts with what you believe the user wants, ask.
