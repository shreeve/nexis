# nexis Phase 1 — Handoff Prompt (write this to the next AI as your first message)

```
You are taking over work on the nexis project — a modern, Zig-native Lisp
inspired by Clojure, built for persistent data, durable identity, and
world-class performance. Multi-phase implementation driven by PLAN.md at
the repository root. Phase 1 is roughly 55% risk-weighted complete; you
are continuing mid-phase from a clean, all-green tree.

The previous AI's final act was to land persistent-vector + retire the
architectural composition risk that peer-AI review had flagged as the
project's primary hidden fault line. Your job is to continue from there
with the same discipline.

Read this entire prompt before touching anything.

═══════════════════════════════════════════════════════════════════════
## 1. REPOSITORY

- Location: /Users/shreeve/Data/Code/nexis/
- Remote:   git@github.com:shreeve/nexis.git
- Branch:   main, tracking origin/main, pushed
- Last commit: 1be3317 Phase 1: persistent vector + cross-kind sequential
               architecture retirement
- Working tree clean. Verify with `git status`.

Phase 1 commit history (most recent first):
  1be3317 Phase 1: persistent vector + cross-kind sequential architecture retirement
  7da0ee0 Phase 1: bignum heap kind (Scope A: construction + canonical form + eq + hash)
  2ec4e7b Phase 1: pin benchmark methodology (docs/BENCH.md + PLAN §19.8)
  9c33cbd Phase 1: narrow eq.equal → eq.equalImmediate (abstraction-debt retire)
  accbb83 Phase 1: cons list + equality-category hash domains
  992f697 Phase 1: string heap kind + central dispatch
  64728ee Phase 1: heap GC-stress property tests
  e857c2d Phase 1 cleanup: split forEachLive, harden asHeapHeader, sync intern doc
  823b394 Phase 1: heap allocator + HeapHeader storage
  195a6ae Phase 1: keyword + symbol intern tables
  99f9ab0 Start Phase 1: hash, Value immediates, and eq — with property tests

═══════════════════════════════════════════════════════════════════════
## 2. REQUIRED READING (strict order — budget ~2.5 hours, do NOT skip)

### 2.1 Authoritative design docs

1. PLAN.md (2,489 lines, ~75 minutes). Especially:
   - §5   Three-representations boundary (non-negotiable)
   - §6   Language semantics (truthiness, equality, nil propagation)
   - §8   Value model (16-byte tagged Value, kind table, metadata matrix)
   - §9   Persistent collections (CHAMP map, 32-way vector, list, transients)
   - §10  Memory management (precise mark-sweep tracing GC)
   - §19  SIMD & performance — especially §19.6 Tier 1/2 projections
             and §19.8 performance gates methodology reference
   - §20.2 Phase 1 gate — THE single most important milestone
   - §21  Roadmap (which Phase 1 modules are shipped / pending)
   - §23  Hard decisions (frozen — each requires an amendment to change)
   - §24  Open questions (deliberately undecided)

2. CLOJURE-REVIEW.md — what we take, adapt, reject from Clojure.
   §4 maps Clojure reader constructs to nexis Forms.

3. docs/FORMS.md — Phase 0 canonical Form schema.

4. docs/SEMANTICS.md — equality, hash, numeric corner cases.
   Frozen. Re-amended in accbb83: §3.2 now specifies
   EQUALITY-CATEGORY domain mixing (not per-kind). Sequential kinds
   share domain byte 0xF0; associative 0xF1; set 0xF2. §2.2 amended
   to fix the asymmetric i48 boundary (fixnum range is
   [-2⁴⁷, 2⁴⁷-1], not ±(2⁴⁷-1)).

5. docs/VALUE.md — 16-byte Value layout, Kind discriminator,
   HeapHeader spec, signed-zero/NaN matrix. Frozen.

6. docs/HEAP.md — allocator contract, prefix-block storage strategy,
   minimal sweep scaffold, 16-byte alignment, poisoned-kind double-
   free detection. Frozen. Note: `sweepUnmarked` is a scaffold, not
   a real collector — root enumeration + tracing live in the future
   `src/gc.zig`.

7. docs/INTERN.md — keyword + symbol intern tables. `split` helper
   with the bare-`/` carve-out (it's the division symbol).

8. docs/STRING.md — UTF-8 string heap kind, subkind 1 only. No
   SSO, no UTF-8 validation at the storage boundary.

9. docs/LIST.md — immutable cons list + Cursor. First collection
   kind; fn-pointer plumbing for element-recursive dispatch.

10. docs/BIGNUM.md — arbitrary-precision integer. Scope A shipped:
    construction + canonical form + equality + hash. **Arithmetic
    deferred** (Scope B, next commit). The canonicalization
    invariant is central: a bignum whose magnitude fits in i48
    cannot exist; all constructors funnel through
    `canonicalizeToValue`.

11. docs/VECTOR.md — plain 32-way persistent vector + tail buffer,
    per PLAN §23 #30. File is named `src/coll/rrb.zig` for
    historical consistency; the v1 impl is NOT RRB-relaxed.
    Four-subkind scheme (root/interior/leaf/tail), streaming Cursor
    pattern, cross-kind list↔vector equality proven.

12. docs/CODEC.md — serialization scope stub. Bytes TBD Phase 4.

13. **docs/BENCH.md** (new in 2ec4e7b) — benchmarking methodology
    pre-commitment. Pins the fairness, accuracy, and honesty
    standards for every performance claim nexis will publish,
    especially against Clojure. Landed before any benchmark code
    deliberately — read it before even thinking about performance
    work.

### 2.2 Contributor + Zig references

14. AGENTS.md — contributor routing guide. Authority order, session
    workflow, Phase 0 exit criteria, common traps.

15. **ZIG-0.16.0-REFERENCE.md + ZIG-0.16.0-QUICKSTART.md — MANDATORY
    before writing any Zig.** 30+ stdlib APIs changed between 0.15
    and 0.16 in ways that silently break training-data code. See
    §6 below for the gotchas that have actually bitten us.

═══════════════════════════════════════════════════════════════════════
## 3. BUILD VERIFICATION (run on arrival)

```
cd /Users/shreeve/Data/Code/nexis
zig build test --summary all
```

Expected: **247 tests pass / 40 build steps succeed** (257 total gates
including 10 golden reader tests). If the tree isn't green, STOP and
diagnose before editing.

Test breakdown at handoff time:
  Inline runtime tests:
   10  hash.zig
   12  value.zig
    9  eq.zig
   12  intern.zig
   26  heap.zig
   14  string.zig
   19  coll/list.zig (incl. Cursor)
   24  bignum.zig
   21  coll/rrb.zig (vector)
   25  dispatch.zig (incl. cross-kind retirement receipts)
   11  reader.zig
  Property tests (test/prop/):
    7  primitive.zig
   10  intern.zig
    8  heap.zig
    6  string.zig
    8  list.zig
   10  bignum.zig
    9  vector.zig
  Golden reader tests:
   10  test/golden/

If you run `zig build parser` for any reason, note it requires
../nexus/bin/nexus to exist. Regenerating src/parser.zig isn't
normally needed unless you're touching nexis.grammar.

═══════════════════════════════════════════════════════════════════════
## 4. ARCHITECTURAL NARRATIVE (things docs won't teach you)

The hard-won insights from 11 sessions of implementation. Read this
carefully — understanding WHY things are the way they are will save
you days of rework.

### 4.1 The dispatch module is a one-way terminal

`src/dispatch.zig` is the central composition point for every heap-
kind operation. It imports value, eq, heap, hash, string, list,
vector, bignum. **Nothing imports dispatch.** This asymmetry isn't
aesthetic — it's forced by a concrete Zig test-runner constraint.

Early in Phase 1 we tried `value.hashValue` directly dispatching to
heap kinds via `@import("dispatch")`. Every test binary for a cycle
member (value.zig, eq.zig, string.zig) failed with:

    src/dispatch.zig:1:1: error: file exists in modules 'root' and 'X'

Zig's test runner makes each source file both the root of its own
test binary AND available as a named module in its own graph. A
cyclic import + "self" appearance violates the "file in only one
module" rule.

**The pattern:** kind modules provide per-kind operations with
callback signatures (e.g., `hashSeq(h, elementHash)`); dispatch
composes them. `value.hashImmediate` (not `hashValue`) panics on
heap kinds pointing users to `dispatch.hashValue`. Same for
`eq.equalImmediate` → `dispatch.equal`. This is a partial-API scar
but it's documented in every panic message and the naming makes
the partialness explicit.

### 4.2 Equality-category hash domains (corrected from the original spec)

SEMANTICS.md §3.2 originally said "every Value.hashValue output has
the per-kind offset folded in." That directly contradicted the
cross-type sequential equality rule `(= (list 1 2 3) [1 2 3]) →
true`. If that must be true, and their hashes must be equal (the
bedrock `= ⇒ hash-eq` law), then they CAN'T have different
per-kind domain bytes folded in.

Amendment landed in accbb83: equality-category domain mixing. The
domain byte is:
  - kind_local → @intFromEnum(Kind)
  - sequential (list, persistent_vector) → 0xF0 (shared)
  - associative (persistent_map) → 0xF1 (shared)
  - set (persistent_set) → 0xF2 (shared)

Chosen outside the 0..29 valid-kind range. The `dispatch.eqCategory`
exhaustive test pins this for every Kind in v1.

### 4.3 The Cursor pattern for cross-kind sequential walks

When vector landed (second sequential kind), `dispatch.sequentialEqual`
needed to walk list-vs-vector pairs. Peer AI pushed back on my initial
`count + nth` proposal because list's `nth` is O(n), making naive
cross-kind equality O(n²), AND because random-access is the wrong
pattern for future sequentials (lazy-seq, cons).

**The pattern:** each sequential kind exposes `Cursor { init, next }`.
dispatch.zig composes them in a `SeqCursor = union(enum) { list, vector }`
and walks pairwise. Same-kind pairs still use the O(n) `equalSeq` fast
paths; cross-kind uses cursors. When lazy-seq and cons arrive, they
add Cursor implementations — no change to dispatch's walk logic.

### 4.4 The bignum canonicalization invariant

A bignum whose magnitude fits in i48 cannot exist. Every constructor
routes through `canonicalizeToValue(heap, negative, limbs)` which
trims trailing zeros, folds zero magnitude to `fixnum(0)` (regardless
of sign — "no signed zero in the integer tower"), folds fixnum-range
magnitudes to fixnum, and only allocates a bignum for genuinely-out-
of-range values. This is what makes `(= fixnum(n) bignum(n)) → true`
hold WITHOUT a cross-kind equality rule: the two forms can't both
exist for the same mathematical value.

Scope B (arithmetic) is the next bignum commit. Every arithmetic
result must re-canonicalize. See docs/BIGNUM.md §9.

### 4.5 The heap is provisional until real GC lands

`Heap.sweepUnmarked` is a scaffold — it walks the live list, frees
unmarked-unpinned blocks, clears marks on survivors. It does NOT
enumerate roots or trace reachability. The collector that will do
that (`src/gc.zig`) doesn't exist yet. Heap kinds must assume GC
may eventually force minor API changes: `HeapHeader.meta`, per-kind
`trace` functions, possibly a tri-color marking scheme, possibly a
temporary-root stack for in-flight allocations during construction.

The `Interner.trace(visitor)` no-op seam is the placeholder for when
GC starts scanning intern tables as roots. Heap objects don't yet
have per-kind trace functions; when gc.zig lands, every heap kind's
module grows one.

### 4.6 Three representations stay distinct (PLAN §5, risk register #1)

Form (parsed source, in `src/reader.zig`), Value (runtime 16-byte
tagged cells), Durable-Encoded (codec wire format, Phase 4). They
only fuse through explicit codec ops. If you find yourself wanting
to reach across the boundary because it's convenient, stop.

═══════════════════════════════════════════════════════════════════════
## 5. SESSION DISCIPLINE (non-negotiable — this is what makes the work good)

Every substantive module commit follows this loop. Skipping any step
has caused real bugs in earlier sessions.

### 5.1 Before writing code

1. Read the relevant frozen docs (SEMANTICS, VALUE, and the per-
   kind doc if it exists).
2. Draft a strategy message to peer AI via `user-ai` MCP with
   `conversation_id: "nexis-phase-1"`. Lay out scope, representation
   options, specific questions. Don't rubber-stamp — peer AI has
   caught real bugs every single turn. Strategy examples:
   - Turn 1: sequential hash domain contradiction (led to amendment)
   - Turn 3: architectural composition hidden fault line (led to V3
             retirement receipt)
   - Turn 6: bignum canonicalization boundary asymmetry
             (led to SEMANTICS §2.2 amendment)
   - Turn 7: `count+nth` cross-kind wrong pattern (led to Cursor)

### 5.2 Spec first

If the module is substantive (a new heap kind, a new dispatch
pattern, a new category), draft `docs/XXX.md` BEFORE the code.
Pin the frozen invariants there. Examples:
  - HEAP.md, INTERN.md, STRING.md, LIST.md, BIGNUM.md, VECTOR.md
    all predate their src/*.zig files.
  - BENCH.md predates any benchmark code deliberately — commitments
    are strongest when they can't be retrofitted against favorable
    measurements.

### 5.3 While writing code

- Peer AI's recommended fixes from the strategy turn get applied
  DURING implementation, not after.
- Property tests land ALONGSIDE the module, not at the end. Every
  module has a test/prop/*.zig file that exercises its invariants
  under randomized workloads.
- Inline unit tests (test "..." blocks) cover structural
  invariants; property tests cover statistical laws.
- Use deterministic PRNG seeds: failures must reproduce.
- `std.testing.allocator` catches leaks at teardown — if your
  `deinit` path forgets something, the test trips.

### 5.4 Before commit

1. Run `zig build test --summary all`. Green = proceed.
2. Engage peer AI for a code review (discuss with the same
   conversation_id, OR use the `review` tool for a structured pass).
3. Apply peer's review items. Do NOT rubber-stamp. Previous turns
   have caught:
   - Unchecked multiplication in body-size calc (bignum turn-7)
   - Padding bytes leaking into semantic hash (bignum turn-6)
   - Const-lie in forEachLive (heap)
   - Missing read-side invariant asserts
4. Run tests again; green.
5. `git add -A && git commit -m "$(cat <<'EOF'\n...body...\nEOF\n)"`
6. `git push origin main`

### 5.5 Git discipline

- Short imperative subject. Body when substantive (and substantive
  means cite the SEMANTICS.md / PLAN.md sections that govern, cite
  the peer-AI turn that caught each fix, call out explicit
  deferrals).
- Split commits along logical lines.
- NEVER --amend a commit that's been pushed.
- NEVER use git commands with -i flag (interactive not supported).
- NEVER --force push to main.
- Commit messages have been substantive — see `git log` for the
  convention. Don't regress to one-line commits.

═══════════════════════════════════════════════════════════════════════
## 6. PEER-AI COLLABORATION (the single biggest quality lever)

The `user-ai` MCP server provides `chat`, `discuss`, `review`,
`status` tools. Use `discuss` with `conversation_id: "nexis-phase-1"`
to maintain continuity across turns.

As of this handoff, the conversation has 8+ turns covering:
  - T1: Strategy for first collection (list); caught spec contradiction
  - T2-3: Step-back survey on project health (honest assessment)
  - T4: Benchmarking methodology discussion
  - T5: Final-review pattern settled
  - T6: Bignum strategy + asymmetric i48 boundary catch
  - T7: Vector strategy + Cursor pattern + 4-subkind scheme
  - T8: Vector code review

**Continue this thread.** Peer AI has earned trust over ~40 substantive
interactions; each session has caught 1-5 real bugs pre-commit. Do
not skip peer engagement even when the task seems simple. The times
it catches nothing are a minority; the times it catches something
load-bearing are frequent.

Invocation example:

  CallMcpTool server="user-ai" toolName="discuss" arguments={
    "conversation_id": "nexis-phase-1",
    "message": "...your substantive question + full context...",
    "model": "gpt-5.4"
  }

Peer AI is GPT-5.4 by default; Claude Opus 4.6 is also available via
model override.

**Pattern:** provide peer with everything they need (relevant spec
text quoted; current design proposals; specific questions; explicit
"don't rubber-stamp" instruction). A one-line question gets a one-
line answer. A substantive briefing gets a substantive critique.

═══════════════════════════════════════════════════════════════════════
## 7. CURRENT STATE — what's shipped, what's pending

### 7.1 Shipped Phase 1 modules

```
Runtime core:
  src/hash.zig        xxHash3-64 + structural combiners + mixKindDomain
  src/value.zig       16-byte tagged immediates; hashImmediate method
  src/eq.zig          identical? + equalImmediate (immediates only)
  src/intern.zig      keyword + symbol intern tables
  src/heap.zig        allocator + HeapHeader + minimal sweep scaffold
  src/dispatch.zig    one-way-terminal cross-kind composition

Heap kinds (three shipped):
  src/string.zig      UTF-8 strings (subkind 1: heap)
  src/bignum.zig      arbitrary-precision integers (Scope A: eq/hash only)
  src/coll/list.zig   immutable cons list + Cursor
  src/coll/rrb.zig    persistent vector (plain 32-way + tail) + Cursor

Phase 0 (still in place):
  src/nexis.zig       @lang module: Tag enum + Lexer wrapper
  src/reader.zig      Sexp → Form normalizer + pretty-printer
  src/golden.zig      golden test runner
  src/parser.zig      GENERATED (do not edit; regenerate via `zig build parser`)
```

### 7.2 Pending Phase 1 modules

```
[ ] src/coll/hamt.zig          CHAMP persistent map + set (§9.1, §23 #37)
[ ] src/coll/transient.zig     owner-token discipline
[ ] src/gc.zig                 real mark-sweep with root enum + tracing
[ ] src/codec.zig              self-describing wire format
[ ] src/db.zig                 emdb integration + durable-ref
[ ] src/bignum.zig Scope B     add/sub/mul with canonicalization
[ ] src/coll/rrb.zig Scope B   assoc / pop / subvec / concat
[ ] src/string.zig subkind 0   inline-short-string optimization
```

### 7.3 Phase 1 gate tracking (PLAN §20.2)

```
1. 100k+ randomized equality/hash tests    PARTIAL (~3k iter across
                                             7 prop files; scaling is a
                                             matter of bumping constants
                                             once all kinds land)
2. Persistent immutability                   PARTIAL (list + vector both
                                             immutable by construction;
                                             CHAMP pending)
3. Transient equivalence                    PENDING (no transients)
4. Transient ownership                      PENDING (no transients)
5. Codec round-trip                         PENDING (no codec)
6. emdb round-trip                          PENDING (no db integration)
7. GC stress                                SHIPPED (test/prop/heap.zig)
8. Interning invariants                     SHIPPED (test/prop/intern.zig)
```

### 7.4 Risk-weighted progress

Peer AI's turn-3 assessment put us at ~35% risk-weighted. After
bignum + vector + BENCH methodology + eq refactor, we're at ~55%.
The biggest hidden fault line — "architecture under cross-kind
composition" — has been RETIRED with the V3 property test in
test/prop/vector.zig (500 random list↔vector sequences `=` and
hash-equal). What remains is mostly (a) apply the proven pattern
to more kinds (CHAMP), (b) systems-heavy work (GC, codec, db).

═══════════════════════════════════════════════════════════════════════
## 8. NON-NEGOTIABLE DISCIPLINE

From PLAN.md §"Start here" and accumulated hard lessons:

1. **Three representations stay distinct** (§5). Form, Value,
   Durable Encoded are separate. They only fuse through explicit
   codec ops. Violating this is how language projects turn into
   tar pits.

2. **Respect PLAN §23 frozen decisions.** 38 decisions committed
   before code was written. Each requires a PLAN amendment with
   stated rationale to change. SEMANTICS.md §2.2 and §3.2 have
   already been amended during Phase 1 to fix real contradictions
   — that's the channel. Do not silently deviate.

3. **Read actual source, don't trust intuition.**
   - For Clojure behavior: grep `misc/clojure/src/jvm/clojure/lang/`.
     The Java core is checked in. Earlier AIs twice confidently
     wrote wrong claims about Clojure and only caught them by
     opening LispReader.java / PersistentVector.java and reading
     the bytes.
   - For Zig 0.16 APIs: read from
     /opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/. Training-data
     code for Zig 0.15 silently breaks in 0.16.

4. **Do NOT widen the v1 non-goals list** (§4) without an amendment.

5. **Do NOT expose benchmarks publicly** until Phase 6 has real
   numbers (§19.7). The plan intentionally under-promises and
   over-delivers. BENCH.md pins the methodology — every
   performance claim must satisfy numerical + accurate + fair +
   relevant (peer AI added "relevant" as the fourth standard).

6. **Honesty clause** (from BENCH.md §8): when benchmarks eventually
   ship, publish scenarios where Clojure wins. Manufactured
   symmetry is worse than admitted losses. External Clojure-
   practitioner review required before any comparative report.

7. **No claim of "reliable" until Phase 1 gate passes.** The
   previous AI's handoff note was blunt about this:
   "foundation yes, product no; credible path, but not yet near a
   reliability claim for the full planned product."

═══════════════════════════════════════════════════════════════════════
## 9. ZIG 0.16 GOTCHAS (things that have actually bitten us)

- `std.ArrayList(T){}` / `= .{}` → `= .empty` (field defaults gone)
- `std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator(.{})`
- `std.fs.cwd()` → `std.Io.Dir.cwd()` (most FS ops take `io: std.Io`)
- `std.io.Writer.Allocating`: `.writer` is a FIELD, not a method
- `std.mem.Alignment.@"16"` for 16-byte alignment
- `std.math.add` / `std.math.mul` for checked arithmetic
- `std.hash.XxHash3` is the available hasher
- **`@ptrCast` requires `@alignCast` when target alignment > source.**
  heap.zig declares HeapHeader and Block with `align(16)` so casts
  between `*HeapHeader` and `[*]align(16) u8` are lossless.
- **Build-graph self-collision**: a source file cannot be both a
  test binary's root AND a named import of the same graph. This
  is why `dispatch` is one-way terminal. See build.zig's
  runtime_test_files loop — each test skips its own name as an
  import.
- **`@intCast(T, v)` is now `@as(T, @intCast(v))`**. `@intCast` is
  a builtin that infers target type from context; old two-arg
  form is gone.
- Unused locals must be `const`, not `var`. (This has tripped
  exactly one test file per session.)
- Multi-char literals in grammar rules: `nexus` generator's token
  name "integer" is hardcoded in the number scanner; `hasIdent`
  dispatch only fires when token name is literally "ident".

═══════════════════════════════════════════════════════════════════════
## 10. IMMEDIATE NEXT TASK — options with peer-AI's thinking

After 1be3317, the architectural composition risk is retired. Peer
AI's turn-6 original sequence was "A→B→C/D with C or D depending
on appetite for semantic vs systems risk." A (eq refactor + BENCH),
B (bignum), and C (vector) are done. The next candidates:

### Option 1: CHAMP (src/coll/hamt.zig) — persistent map + set

The last frozen major collection (PLAN §23 #37). 32-way branching,
separate data/node bitmaps, canonical layout. Listed as the biggest
remaining implementation risk in PLAN's risk register. Ships two
kinds at once (map and set share code). Unblocks
`{:a 1 :b 2}` literals for Phase 2 reader→Value lifting.

Estimated 1000-1500 LOC across 2-3 sessions. Spec first
(docs/CHAMP.md before code). Reuses the Cursor pattern from
vector. The third and final equality category (associative, set)
becomes observable.

### Option 2: Real GC (src/gc.zig)

Biggest remaining systems risk. Heap scaffolding is provisional.
Will likely force API changes to per-kind modules (trace functions,
root registration). Phase 1 gate test #7 becomes fully meaningful
(currently uses hand-marking instead of root-walk).

Estimated 400-700 LOC. Draft docs/GC.md first; pin the root
enumeration strategy and the trace dispatch pattern. Each existing
heap kind grows a `trace(h, visitor)` method.

### Option 3: Bignum Scope B — arithmetic

Completes the integer tower functionally. No architectural risk;
all patterns already proven. Not on the Phase 1 gate critical path
because no code path calls arithmetic yet (VM is Phase 2).

Estimated 500-800 LOC. Reader extension for bignum literals is
also part of this commit (so reader can produce out-of-range
integer Values directly).

### Option 4: Transients (src/coll/transient.zig)

Cross-cuts collections. The owner-token discipline is well-specified
in PLAN §9.4. Requires map/set to be shipped first before it's
meaningfully useful (list doesn't need transients; vector could
use them but it's one kind). So probably after Option 1.

### My lean, and why I'd check with peer AI before starting

**CHAMP (Option 1) is the most-valuable next unit.** Reasons:
  - The associative and set categories are the only hash-domain
    categories still hypothetical. Shipping CHAMP makes
    `(= {:a 1} {:a 1}) → true` and the associative-domain
    0xF1 byte observable for the first time. That's the last
    piece of the equality-category design to validate.
  - It's the biggest remaining implementation risk per PLAN's
    risk register.
  - It unblocks map literals for Phase 2 (same reason vector
    unblocked vector literals).
  - It's a natural sequel to the vector session — the trie
    structure is similar shape (branching factor, path-copy,
    immutable updates).

But: GC (Option 2) is the biggest systems risk. If you want to
retire systems risk before more semantic risk piles up on top,
start there. Check with peer AI via `discuss` before committing.

### Other smaller items deferred from prior sessions (would add at
### the end of whichever big commit you pick)

- FailingAllocator tests for errdefer chains (peer-AI-agreed
  follow-up; 30 minutes of work)
- Lightweight microbench of Heap.free's O(n) scan (peer-AI turn-3
  "measure something soon"; informational)

═══════════════════════════════════════════════════════════════════════
## 11. THE QUALITY BAR — what makes this project world-class vs just
## competent

This is the cultural context the code-level details won't transmit.

### 11.1 What we're building

nexis aims to be "the fastest interpreter-tier Lisp ever shipped"
(PLAN §19.7 aspiration, not a shipping guarantee). Against Clojure
specifically:
  - Dramatically crisper on cold start (script-style, <5ms vs ~200ms
    JVM warmup)
  - Competitive-to-faster on collection work (CHAMP vs Bagwell HAMT,
    SIMD-friendly layouts)
  - Substantially faster on database-integrated workloads (emdb as
    a first-class language concept, not an external library)

These are ambitions. They are only legitimate if backed by:
  1. Correctness that's proven by property tests at the invariant
     level, not just example tests.
  2. Benchmarks that survive peer review from a Clojure practitioner
     (BENCH.md §9 requires this).
  3. Honest publication of scenarios where Clojure wins.

### 11.2 What "world-class" means for this project

Not "has lots of features" — v1 is deliberately narrow (PLAN §4
non-goals: no protocols, no STM, no agents, no core.async, no
reader conditionals, no multimethods, no tagged literals).

"World-class" means:
  - **Internally consistent** — the SEMANTICS.md →
    dispatch.zig → per-kind-module chain has no silent
    contradictions. When we find one (bignum canonicalization
    bounds; sequential hash domain), we amend the spec, not paper
    over the code.
  - **Tested at the right level** — 257 gates today, growing to
    100k+ randomized iterations by Phase 1 exit (§20.2 test #1).
    Every invariant has a property-test retirement receipt.
  - **Benchmarked honestly** — BENCH.md §11's summary sentence:
    "We measured several clearly defined performance regimes,
    with published source and methodology, and here is where
    nexis is faster, where it is comparable, and where Clojure
    wins." No report that can't survive that sentence ships.
  - **Spec-first, not code-first** — every frozen invariant
    lands in a doc BEFORE code can violate it. Amendments happen
    through PR-style doc edits, not commit messages.
  - **Honest about progress** — the previous AI's handoff was blunt
    about the ~35% → ~55% risk-weighted progress vs ~60% →
    ~70% LOC-weighted. Don't conflate "shipped foundation" with
    "retired project risk."

### 11.3 What breaks the quality bar

- Writing code before drafting the spec for a substantive module.
- Skipping peer AI review ("this is obviously right" is usually
  when it isn't).
- Publishing performance claims that haven't been through BENCH.md
  discipline.
- Manufactured test coverage (tests that only exercise the happy
  path; fixed-input tests where properties should live).
- Silent deferral of hard design decisions ("I'll just ship and
  fix it later"). Defer explicitly in the doc and commit message,
  or don't defer.
- Letting the test count drift down for any reason. Every commit
  lands with at least the same number of tests that were passing
  at its parent. Prefer more.

### 11.4 Final word from the outgoing AI

What made Phase 1 work across 11 commits:
  - Spec-first pinning of every invariant in docs/ before writing
    code. The existence of SEMANTICS.md §3.2's equality-category
    amendment commit is proof the discipline works: we found a
    real internal contradiction and fixed it at the spec level
    before the code diverged.
  - Every substantive commit engaged peer AI at strategy AND at
    review, with `conversation_id: "nexis-phase-1"`. Peer AI has
    caught about one real bug per session before commit. That
    number compounds over phases.
  - Freeze-before-implement. BENCH.md was landed before any
    benchmark code. docs/HEAP.md was drafted before src/heap.zig.
    Deferring specification invites hand-waving.
  - Honest reporting. The step-back survey (turn-3) that put
    risk-weighted progress at ~35% when LOC-weighted was ~57%
    was harder to write than a cheerleading update but made every
    subsequent decision better.

Phase 1 gate (PLAN §20.2) is the single most important milestone
in the whole project. Don't rush it. Plan for slack.

The force remains with you.

═══════════════════════════════════════════════════════════════════════
## 12. WHAT TO DO IN YOUR FIRST MESSAGE

1. Read PLAN.md (75 min). Do not skim §20.2, §23, §21.
2. Read at minimum: AGENTS.md, ZIG-0.16.0-REFERENCE.md,
   docs/SEMANTICS.md, docs/VALUE.md, docs/HEAP.md, docs/BENCH.md,
   plus the doc for the kind you'll touch next (VECTOR.md if
   extending vector; BIGNUM.md if Scope B; none specific if
   starting CHAMP or GC from scratch).
3. Run `zig build test --summary all`. Confirm 247 tests, 40
   build steps, all green.
4. Run `git log --oneline -15` and `git status`. Confirm you're
   at 1be3317 on a clean main tracking origin/main.
5. Post a short status summary:
   - What you read.
   - Build status with exact test count.
   - Proposed next module (default: CHAMP per §10 Option 1,
     but argue for whichever you prefer with reasons).
   - Any clarifying questions.
6. After user confirms, engage peer AI via `user-ai` MCP with
   `conversation_id: "nexis-phase-1"` for a strategy check on
   your chosen module BEFORE writing code.

Good luck. Every commit you ship is already being reviewed by
peer AI, by the user, and by the quality bar in §11. Hold the
line.
```

---

A few notes about the handoff mechanics:

- **Conversation thread**: The `conversation_id: "nexis-phase-1"` is ~40 substantive turns deep. The new AI inherits that context just by using the same ID — peer AI will remember everything we've discussed. Worth flagging in case they wonder why peer AI seems to know so much.
- **Commit SHA**: `1be3317` is the reference point. They should verify they're at that commit before anything else.
- **Test count**: `247 inline + 10 goldens = 257 total gates, 40 build steps`. That number is their ground truth for "clean starting state."
- **The handoff is intentionally long** (~4,000 words). The original prompt you gave me was similarly long and it worked because it didn't skip anything the incoming AI needed. This one follows the same pattern — better to include too much than to send an AI into the project blind.
