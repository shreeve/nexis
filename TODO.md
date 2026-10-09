# TODO.md — problems found and not yet fixed

Problems found while measuring and reviewing the tree that no other
document tracks. `HANDOFF.md` §6 holds the known gaps and §8 the order
of work; an item here moves there, or into a commit, when it is taken
up. Every fix starts with its failing test (`AGENTS.md`).

---

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
4. **Durable commits cost two device flushes.** A `:durable` commit
   is 2.24 ms against Datalevin's 2.02 ms on the Linux host
   (`docs/PERF.md` §3.15): emdb syncs data, then meta, with two
   `fdatasync`, where Datalevin issues one and an `O_DSYNC` meta
   write. The commit protocol is emdb's; nexis changes nothing in emdb
   (`AGENTS.md`), so this is the engine owner's call. emdb needs the
   two ordered barriers, data before the meta page (its INV-T07A and
   INV-M02; it keeps no write-ahead log); a cheaper second barrier, an
   `fdatasync` of the data then a `pwrite` of the meta page through an
   `O_DSYNC` descriptor, keeps that order, and is an emdb candidate
   with this measurement as its reason, not yet scheduled.

13. **A captured local, and `sort`, keep the seq.** The compiler clears a local
    or a parameter at its last move (`docs/COMPILER.md` §4.9), and the
    natives that walk a sequence to its end consume it (`docs/GC.md`
    §11.5), so `(let [s (map inc (range n))] (count s))` and `(defn
    total [xs] (reduce + xs))` run in constant memory (`docs/PERF.md`
    §3.29, §3.31). A local a closure captures stays in its cell while
    the closure runs, so `(delay (reduce + s))` holds `s` where
    Clojure clears a `^:once` body's fields; clearing a cell needs a
    cell write `docs/VM.md` §6 rules out, and its own design. `sort`
    and `sort-by` do not consume their seq either: they gather every
    element before they sort (`docs/LAZY.md` §9).
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

20. **The store is 1.24× Datalevin's and 2.9× Datomic Pro's.**
    100,000 entities of five attributes take 51 MB on the Apple M5 and
    52 MB on the Linux host, against Datalevin's 42 MB without history,
    Datomic Local's 25 MB and Datomic Pro's 18 MB (`docs/PERF.md`
    §3.36). The remaining gap to Datomic is its block-compressed
    segments, which byte keys in index order refuse; `docs/PERF.md` §6
    "Store size" lists what is left and what was declined.

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
    re-import their stores after upgrading. emdb keeps one current
    format, changed when a measured gain justifies it, with no freeze
    planned; it names both versions when it refuses a file, and its
    own dump and load (`emdb -d`, `emdb -l`) carry a store across a
    format change. If emdb freezes its format, set the policy: which
    releases read which stores, and whether nexis carries a tool that
    exports a store and imports it into a new one.

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
