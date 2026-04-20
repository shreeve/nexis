# AGENTS.md — routing guide for contributors and AI sessions

Short version: read `PLAN.md` end-to-end before you do anything else.

---

## What this project is

**nexis** is a Zig-native Lisp inspired by Clojure, with a first-class durable
identity model backed by `emdb`. See `PLAN.md` §0–§1 for the full pitch.

Current status: **Phase 0**. The reader grammar, `@lang` module, canonical
Form schema, pretty-printer, and golden-test infrastructure are landed. No
runtime, no compiler, no collections — those are Phase 1+ (`PLAN.md` §21).

---

## Required reading (in order)

1. **`PLAN.md`** — the authoritative design. Budget 60–90 minutes. Especially:
   - §5 (three representations — non-negotiable boundary)
   - §23 (hard decisions — frozen commitments; changing one requires an amendment)
   - §24 (open questions — deliberately undecided)
   - §28 / Appendix C (canonical Form schema)
2. **`CLOJURE-REVIEW.md`** — what we take, adapt, and reject from Clojure.
3. **`docs/FORMS.md`** — Appendix C lifted into a standalone contract plus
   the pretty-printer spec and stage-ownership table.
4. **`docs/SEMANTICS.md`** — equality/hash/numeric-edge-case spec (frozen).
5. **`docs/CODEC.md`** — serialization stub (scope frozen, bytes TBD Phase 4).
6. **`docs/NEXTOMIC.md`** — post-v1 Datomic-class database architecture on
   nexis + emdb. Not a v1 deliverable; read only when Nextomic is being
   scoped or when a v1 decision might preclude it.
7. **`ZIG-0.16.0-REFERENCE.md`** + **`ZIG-0.16.0-QUICKSTART.md`** — mandatory
   before writing any Zig. 30+ stdlib APIs changed between 0.15 and 0.16 in
   ways that silently break training-data code.

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

- `zig build parser`  — regenerates `src/parser.zig` from `nexis.grammar`
  by invoking `../nexus/bin/nexus` (the nexus binary must exist).
- `zig build test`    — runs reader unit tests + golden-file verification.
- `zig build golden`  — golden diff alone.
- `zig build golden -Dupdate=true` — rewrite expected files in place
  (use only when intentionally changing schema; commit diffs together).

The generated `src/parser.zig` **is** committed — it is the authoritative
artifact for consumers. Regenerate it whenever you edit `nexis.grammar`.

---

## Repository layout

See `PLAN.md` §22 for the full tree. Phase 0 populates:

```
nexis/
├── PLAN.md                      authoritative design
├── CLOJURE-REVIEW.md
├── ZIG-0.16.0-{REFERENCE,QUICKSTART}.md
├── README.md
├── AGENTS.md                    this file
├── build.zig, build.zig.zon
├── nexis.grammar                reader grammar (source of truth)
├── src/
│   ├── nexis.zig                @lang module: Tag enum + Lexer wrapper
│   ├── parser.zig               GENERATED — do not edit by hand
│   ├── reader.zig               Sexp → Form normalizer + pretty-printer
│   └── golden.zig               golden test runner
├── docs/
│   ├── FORMS.md                 Appendix C expanded
│   ├── SEMANTICS.md             equality/hash/numeric semantics
│   └── CODEC.md                 serialization scope stub
├── test/golden/
│   ├── basic.{nx,sexp}
│   ├── reader-literals.{nx,sexp}
│   └── errors/*.{nx,err}
├── bin/                          build output (nexis-golden, later tools)
└── stdlib/, examples/, misc/clojure/ (reference)
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
   ▼   src/macroexpand.zig   (future — expand syntax-quote, user macros)
expanded Form
   │
   ▼   src/resolve.zig       (future — bind symbols)
Resolved AST
   │
   ▼   src/analyze.zig → src/compile.zig
bytecode
```

Violating a stage boundary is how language projects turn into tar pits
(`PLAN.md` §5). If you find yourself wanting to peek past the current stage
because it's convenient, stop.

---

## Common traps (save yourself time)

- `std.heap.GeneralPurposeAllocator` is **gone** in 0.16.0. Use
  `std.heap.DebugAllocator(.{})` or the `init.gpa` from `pub fn main(init:
  std.process.Init)`. See `ZIG-0.16.0-QUICKSTART.md`.
- `std.fs.cwd()` → `std.Io.Dir.cwd()`; most FS ops now take `io: std.Io`.
- `std.io.Writer.fixed` → `std.Io.Writer.fixed`. `std.io.fixedBufferStream`
  is gone.
- **Nexus-specific:** the token name `integer` is hardcoded inside the
  generated scanner. Name your number token `integer`, not `int`. Likewise,
  nexus only emits the `isLetter → scanIdent` dispatch when your token is
  named `ident`; use `IDENT` in parser rules and wrap it into whatever
  semantic tag you want via the action template.
- **Multi-char literals** in grammar rules (e.g. `"~@"`, `"#{"`) are **not**
  auto-mapped to their tokens. Add an `@op` directive.

---

## Session workflow for contributors / AI sessions

1. `zig build parser && zig build test` before your first edit. If the tree
   doesn't build clean, stop and fix the environment first.
2. Make the smallest change that actually addresses the task.
3. If you touch `nexis.grammar`, `src/nexis.zig`, or `src/reader.zig`:
   regenerate the parser and re-run goldens. If a golden changed
   semantically, update it with `-Dupdate=true` and inspect the diff in
   your commit.
4. If you touch documentation, cite the PLAN.md section that grounds your
   change.
5. Write Zig tests inline in the module you edited. Don't add a new test
   file unless scoping truly demands it.

---

## Phase 0 exit criteria (`PLAN.md` §21)

- [x] `nexis.grammar` produces a parser that accepts all §7.2 reader forms.
- [x] `src/nexis.zig` provides the `Tag` enum and a Lexer wrapper.
- [x] `src/reader.zig` normalizes Sexp → Form per FORMS.md §3.
- [x] `docs/{FORMS,SEMANTICS,CODEC}.md` exist and cross-cite `PLAN.md`.
- [x] Golden tests for happy paths and every reader error listed in §28.3.
- [x] `zig build test` green.

Once you have all of the above, you are ready to start Phase 1
(`PLAN.md` §21 — runtime core, value layer, collections, GC, codec).
Before proceeding, reread `PLAN.md` §20.2 Phase 1 gate — the bar is 100k+
randomized equality/hash tests and codec round-trip invariants. Plan for
that from day one.

---

## Non-negotiable discipline (from `PLAN.md` §"Start here")

1. **Do not break the three-representations boundary** (§5). Form, Value,
   Durable Encoded are distinct. They only fuse through explicit codec ops.
2. **Respect SCVU operand-kind encoding** (§12.2) when Phase 2 lands.
3. **Do not widen the v1 non-goals list** (§4) without an amendment.
4. **Do not expose benchmarks publicly** until Phase 6 has real numbers
   (§19.7). The plan intentionally under-promises and over-delivers.

If any of this conflicts with what you believe the user wants, **ask**.
Do not silently deviate from frozen decisions.
