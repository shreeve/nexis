# TODO.md — problems found and not yet fixed

Problems found while measuring and reviewing the tree that no other
document tracks. `HANDOFF.md` §6 holds the known gaps and §8 the order
of work; an item here moves there, or into a commit, when it is taken
up. Every fix starts with its failing test (`AGENTS.md`).

---

## Gaps

14. **Nextomic refuses a datom form written as a list.** `[(list
    :db/add e a v)]` is `:nextomic/tx-data` ("a form is a vector or a
    map"); Datomic accepts any sequential form, and a lazy seq of forms
    is already converted at the boundary. Accept a list where a vector
    form is accepted (`docs/NEXTOMIC.md` §3).
15. **`load-string` refuses a syntax-quote.** It reads each form as
    data and evaluates it, and a syntax-quote has no data form (the
    reader leaves a marker the macroexpander expands), so text holding
    one is `:reader-error`; Clojure loads it. Compiling each Form as
    read, through a hook beside `CompilerHooks` (`src/compile.zig`),
    would load it as a file does (`docs/STDLIB.md`, `load-string`).

## Performance

2. **Small transactions.** 20,000 `transact!` calls of one entity with
   five attributes measured about 230 μs each on the Apple M5, under a
   load average of 16, where `docs/PERF.md` §3.11's 1,000 one-datom
   transactions take about 17 μs each. Remeasure on a quiet host
   (`bench/compare/db/` shapes, an optimized build), then profile:
   resolving the unique attribute and the upsert, the ident cache, and
   the per-transaction work of `src/nextomic/transact.zig` are the
   first suspects.
3. **`sort` holds memory outside the heap.** Its resident set is
   157 MB against babashka's 114 MB (`docs/PERF.md` §3.11): about
   80 MB of the buffers it sorts through are allocated outside the
   collected heap (`docs/PERF.md` §6, "`sort`'s buffers").
4. **Durable commits cost two device flushes.** A `:durable` commit
   is 2.24 ms against Datalevin's 2.02 ms on the Linux host
   (`docs/PERF.md` §3.15): emdb syncs data, then meta, with two
   `fdatasync`, where Datalevin issues one and an `O_DSYNC` meta
   write. The commit protocol is emdb's; nexis changes nothing in emdb
   (`AGENTS.md`), so this is the engine owner's call.

13. **A lazy seq a local holds keeps what it realized.** A native's
    call block is cleared when it returns, and the natives that walk a
    sequence to its end (`reduce`, `frequencies`, `group-by`, `some`,
    `every?`, `last`, `dorun`) consume it (`docs/GC.md` §11.5), so a
    pipeline passed straight to one runs in constant memory: `(reduce
    + (map inc (filter even? (map inc (range 3000000)))))` peaks at 21
    MB (`docs/PERF.md` §3.21). A seq bound to a local, or passed to a
    closure, whose argument is its own slot, stays held by the slot
    until it is reused: `(let [s (map inc (range n))] (reduce + s))`
    and `(defn total [xs] (reduce + xs))` keep everything they walk,
    where Clojure's locals clearing lets it go. Clearing a local after
    its last use needs liveness in the compiler and an instruction or
    a flag per cleared local; `count`, `into`, `vec` and the other
    natives that walk to the end could consume their argument too.
## Store size

5. **The per-tree table cannot be refreshed.** `docs/PERF.md` §3.11's
   table of entries, bytes, leaves and fill per tree came from a
   program over emdb's `treeStat` and a cursor walk that is not in the
   repository, and it measures the two-pass write order that
   `docs/NEXTOMIC.md` §2.5 no longer uses. Commit the tool (a `bench`
   category or a `zig build` step), then remeasure the table.
6. **Small transactions leave half-full leaves.** emdb fills a leaf to
   nine tenths only while one write transaction continues an ascending
   run (emdb `SPEC.md` INV-SP03); a stream of one-key transactions into
   the same gap (a new entity's EAVT rows before the transaction
   entities, the end of an attribute's AEVT run) splits each leaf in
   half. A per-page record of the last insert position, kept across
   transactions as InnoDB keeps one, would fill them. It is an engine
   question for emdb's owner, not a nexis change.

## Build and environment

7. **CI builds against unpinned siblings** (`HANDOFF.md` §6.4 #3):
   `shreeve/emdb` and `shreeve/nexus` at their default branches. The
   owner decides whether to pin each to a ref.
8. **The Linux comparison host's toolchain.** The host of
   `docs/PERF.md` §3.15 keeps its tools under `~/nexis-bench`, whose
   Zig is older than `build.zig.zon`'s `minimum_zig_version`; install
   the matching Zig there before rerunning `bench/compare/run.clj`
   (each download is the owner's to approve).

## Deferred design

Each needs a PLAN amendment before code (`AGENTS.md`, authority order).

10. **Multimethods.** `defmulti`, `defmethod`, `remove-method`,
    `methods`, `prefer-method` with `:default`, and hierarchies
    (`derive`, `isa?`, `parents`, `ancestors`, `descendants`,
    `make-hierarchy`). Deferred by the owner to the next revamp
    (PLAN §4 lists them as absent).
11. **`&form` and `&env` in macros** (PLAN §23 #34, §24 #13). A macro
    receives the call's Form (its span and metadata) and the map of
    locals in scope. Deferred by the owner to the next revamp.
12. **FileMan on Nextomic.** VistA's FileMan data gains Nextomic's time
    model: every fact kept, as-of reads, provenance on each change.
    `docs/FILEMAN-NEXTOMIC.md` has the mapping from `^DD`, the three
    ways to combine them (a temporal mirror first) and a first
    demonstration. The capture hook belongs to em's repository.

## Divergences by design, not bugs

9. **`/` by a float zero.** nexis always raises `:divide-by-zero`,
   Clojure's rule for boxed operands. Clojure is IEEE when its compiler
   sees a primitive double operand, so `(/ 1.0 0)` typed at a Clojure
   REPL is `##Inf` (`CLOJURE-REVIEW.md` §4.3, PLAN Amendment Log). A
   report of it is answered there.
