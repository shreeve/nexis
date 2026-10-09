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
4. **A durable commit writes more pages than Datalevin's.** A
   `:durable` Nextomic commit of one datom is 2.22 ms against
   Datalevin's 1.98 ms on the Linux host, 1.12× (`docs/PERF.md` §3
   "Durable commits"). The flushes are not the difference: emdb's
   durable commit runs level with LMDB's (515 against 521 commits a
   second on ext4), its second flush costs the same in any form, and
   nexis adds no sync or write of its own (two `fdatasync` and no
   other system call a commit). The gap is the pages: the transaction
   writes 14 of 16 KiB where Datalevin writes 13 of 4 KiB, at about
   35 μs a page, and 6 or 7 of the 14 are the transaction entity's
   `:db/txInstant` datom and the history Datalevin does not keep.
   Every lever left changes the store's format (`docs/PERF.md` §6
   "Fewer pages per durable commit"); none is scheduled.

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
18. **Loads that wait on stores they cannot forward on x86-64.** The
    native boundary agrees (`docs/VM.md` §8), and `count`, `nth` and
    `nthnext` return in place, which leaves the destructuring loop
    0.03 M blocked loads (`docs/PERF.md` §3.40, §3.41). Other rows
    still block: a map literal's entries sorted by
    `std.mem.sortUnstable` in `champ` (6.7 blocked loads a three-entry
    literal, the pipeline's setup), `assoc` into a map (`assocOne`,
    `champ.mapAssoc`: the map build's 2.9 M) and `vector.conj` (the
    vectors' 2.2 M). Two ways around the sort cost more than they saved
    (`docs/PERF.md` §6 "A native's result assembled in a temporary",
    "A map literal's sort").
19. **A leaf native called through a Var pays a whole call.** `(nth v
    i)` or `(even? x)` is `var:load-var`, the argument moves and
    `call:call` into `callLeaf`, about 240 instructions above a
    counting-loop iteration (the micro kit's `leaf1` and `vnth`,
    `docs/PERF.md` §3.37 "Var calls"). Fusing the load with its call
    and calling in place without the moves removed 3–6% and 7–21% of
    that, short of the bars they had to meet, and were not kept
    (`docs/PERF.md` §6). An instruction trace of one `leaf1` iteration
    puts the call at 107 instructions beside the native's own body,
    most of those the out-of-line part's frame, tests and safe point;
    the body, `count` of a vector, is 61 as a leaf that calls the
    general native and 38 fewer on the M5 as a body of its own
    (`docs/PERF.md` §3.37, §3.41). The levers left are the other
    natives' leaf bodies and that part, and a cache at the call site
    must still see the Var's latest root (PLAN §23 #20;
    `docs/PERF.md` §6 "Inline caches at call sites").

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
22. **`#inst` literals** (PLAN §4, §24 #3). Instants are the record
    `nexis.time.Instant` (`docs/STDLIB.md` §12), which prints as
    `#nexis.time.Instant{:ms n}` and has no literal. Doing `#inst`
    cleanly is more than the reader: (a) amend PLAN §4 to drop the
    `#inst` row and §28 to say what `#inst "..."` reads as; reading it
    as the form `(nexis.time/parse "...")`, as `#()` reads as the form
    it stands for, needs no new Form variant, but `nexis.edn/read-string`
    would then return a list, not an instant, so data does not round
    trip; (b) so the reader, the printer (`#inst "2026-..."` for an
    Instant, `src/format.zig`) and `nexis.edn` change together, with
    a golden for each; (c) `compare` of two Instants
    (`docs/SORTED.md` §6), so they sort; (d) Nextomic's marshal takes
    an Instant where it takes an instant's long. (c) and (d) are worth
    doing without the literal.
23. **UUIDs are strings.** `random-uuid` returns the canonical text,
    as Nextomic's `:db.type/uuid` takes and returns it (`docs/STDLIB.md`
    §8, `docs/NEXTOMIC.md` §2). A UUID value would be a new value kind
    (PLAN §23: the Form, the value layer, the codec's wire tags, `=`
    and `hash`, the printer's `#uuid`), and it would break `uuid?` and
    every program and store that holds the text. If a distinct type is
    wanted, a record `nexis.uuid.UUID`, as `nexis.time.Instant` is, needs
    no amendment; it waits on a use that the string cannot serve.

## Divergences by design, not bugs

9. **`/` by a float zero.** nexis always raises `:divide-by-zero`,
   Clojure's rule for boxed operands. Clojure is IEEE when its compiler
   sees a primitive double operand, so `(/ 1.0 0)` typed at a Clojure
   REPL is `##Inf` (`CLOJURE-REVIEW.md` §4.3, PLAN Amendment Log). A
   report of it is answered there.
