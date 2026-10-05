# TODO.md — problems found and not yet fixed

Problems found while measuring and reviewing the tree that no other
document tracks. `HANDOFF.md` §6 holds the known gaps and §8 the order
of work; an item here moves there, or into a commit, when it is taken
up. Every fix starts with its failing test (`AGENTS.md`).

---

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

## Divergences by design, not bugs

9. **`/` by a float zero.** nexis always raises `:divide-by-zero`,
   Clojure's rule for boxed operands. Clojure is IEEE when its compiler
   sees a primitive double operand, so `(/ 1.0 0)` typed at a Clojure
   REPL is `##Inf` (`CLOJURE-REVIEW.md` §4.3, PLAN Amendment Log). A
   report of it is answered there.
