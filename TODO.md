# TODO.md — problems found and not yet fixed

Problems found while measuring and reviewing the tree that no other
document tracks. `HANDOFF.md` §6 holds the known gaps and §8 the order
of work; an item here moves there, or into a commit, when it is taken
up. Every fix starts with its failing test (`AGENTS.md`).

---

## Gaps

17. **`reduce` over an infinite range roots neither its element nor
    its accumulator across a step** (`src/stdlib.zig` `reducePure`,
    `.range_inf`). Past the fixnum range each element is a bignum the
    next step allocates, so a collection then could free the element
    the callback has cleared (`docs/COMPILER.md` §4.9) or the result it
    returned. `(range)` reaches the bignums only after 2^47 elements,
    which no test reaches; root both in the scope's slots as the
    `.iterate` branch does, with a test that builds the range near
    the fixnum limit.

## Performance

2. **Small transactions are emdb's page work.** A `transact!` of one
   new entity with five attributes, one unique, takes 244k
   instructions and about 20 μs on the Apple M5 in an optimized build
   (`docs/PERF.md` §3.27; the 230 μs first reported here does not
   reproduce in an optimized build, and a debug build takes about
   750 μs). It dirties 31 pages of 16 KiB (19
   for one changed datom): the root-to-leaf path of every index tree
   it writes, the txlog, `sys` and emdb's own trees. emdb copies each
   page on its first write and checksums it at commit; 79% of the
   transaction's instructions are inside emdb (55% in its puts,
   copy-on-write included, 15% in the commit), 21% in Nextomic, no
   part of which is over 5%. The commit protocol is emdb's; nexis
   changes nothing in emdb (`AGENTS.md`), so the page work is the
   engine owner's call. On the nexis side the levers left are batching
   (`docs/PERF.md` §6 "Batched commits") and a smaller page, which
   changes the format's key bound (`docs/NEXTOMIC.md` §2).
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

13. **A captured local, and the natives that walk without consuming,
    keep the seq.** The compiler clears a local or a parameter at its
    last move (`docs/COMPILER.md` §4.9), and the natives that walk a
    sequence to its end (`reduce`, `count`, `into`, `vec`,
    `frequencies`, ...) consume it (`docs/GC.md` §11.5), so `(let [s
    (map inc (range n))] (count s))` and `(defn total [xs] (reduce +
    xs))` run in constant memory (`docs/PERF.md` §3.29, §3.31).
    `sort`, `sort-by`, `set`, `reverse`, `butlast`, `mapv`, `filterv`,
    `apply`, `zipmap`, `select-keys` and `nexis.string/join` still hold
    their argument while they walk it (`docs/LAZY.md` §9): each needs
    `NativeFn.consumes` and a walk that roots what it keeps of the
    elements behind its place (`set` also a build as fast as its bulk
    one, which a transient is not). A local a closure captures stays
    in its cell while the closure runs, so `(delay (reduce + s))`
    holds `s` where Clojure clears a `^:once` body's fields; clearing
    a cell needs a cell write `docs/VM.md` §6 rules out, and its own
    design.
18. **Calls on x86-64 save callee-saved registers.** `fastCall` saves
    six, `fastCallSelf` four and the comparisons three (`zig build
    codegen`; `docs/PERF.md` §6 "Frameless fast handlers on x86-64"),
    and `fib` runs 6.0× behind warm JVM Clojure on the Linux host
    (`docs/PERF.md` §3.15; `HANDOFF.md` §8 item 1). The `preserve_none`
    calling convention for every handler, or handlers that take their
    operands in System V's argument registers as em's runtime does,
    would remove the saves; either needs the x86-64 host to run the
    gate and to measure.
19. **A leaf native called through a Var pays a whole call.** `(nth v
    i)` or `(even? x)` is `var:load-var`, the argument moves and
    `call:call` into `callLeaf`, about 240 instructions above a
    counting-loop iteration (the micro kit's `leaf`, `docs/PERF.md`
    §3.29). A cache of the Var's leaf at its call site must still see
    the Var's latest root (PLAN §23 #20; `docs/PERF.md` §6 "Inline
    caches at call sites"), so it needs its own design.

## Store size

20. **The store is 3.1× Datalevin's and 7.6× Datomic Pro's.** 100,000
    entities of five attributes take 144 MB against Datalevin's 46 MB
    on the Apple M5 (`docs/PERF.md` §3.11), and 137 MB against
    Datalevin's 42 MB, Datomic Local's 25 MB and Datomic Pro's 18 MB
    on the Linux host (§3.15). Half is the four history trees and the
    txlog, which Datalevin does not keep; Datomic Local's EAVT holds
    about 8 bytes a datom, Nextomic's 26 bytes of key and value plus
    emdb's 10, and again in its history twin. #5 and #6 are two of its
    parts; `docs/PERF.md` §6 "Store size" lists the levers.

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
   owner decides whether to pin each to a ref. A release builds every
   target from one emdb commit, which it records (`HANDOFF.md` §6.4).
8. **The Linux comparison host's toolchain.** The host of
   `docs/PERF.md` §3.15 keeps its tools under `~/nexis-bench`, whose
   Zig is older than `build.zig.zon`'s `minimum_zig_version`; install
   the matching Zig there before rerunning `bench/compare/run.clj`
   (each download is the owner's to approve).
21. **No store-format compatibility across releases.** emdb's file
    format is not frozen and emdb does not migrate a file between
    formats, so a release may refuse a store another release wrote
    (`docs/DB.md` §1, `docs/NEXTOMIC.md` §2), and users recreate or
    re-import their stores after upgrading. Once emdb freezes its
    format, set the policy: which releases read which stores, and
    whether nexis carries a tool that exports a store and imports it
    into a new one.

## Deferred design

Each needs a PLAN amendment before code (`AGENTS.md`, authority order).

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
