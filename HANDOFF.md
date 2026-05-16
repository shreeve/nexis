# nexis Phase 2 — Handoff Prompt (write this to the next AI as your first message)

```
You are taking over work on the nexis project — a modern, Zig-native Lisp
inspired by Clojure, built for persistent data, durable identity, and
world-class performance. Multi-phase implementation driven by PLAN.md at
the repository root.

Phase 1 is COMPLETE — all 8 gates closed (PLAN.md §20.2). Phase 2 is in
progress: VM kernel and the tiny compiler for `(+ 1 2)` have shipped
(steps #1 and #2 of COMPILER.md §10's 11-step sequence). Step #3
(conditionals: `jump:*` opcodes + `if` lowering) is next, against a
spec that is fully converged from three peer-AI strategy/review turns.

Read this entire prompt before touching anything.

═══════════════════════════════════════════════════════════════════════
## 1. REPOSITORY

- Location: /Users/shreeve/Data/Code/nexis/
- Remote:   git@github.com:shreeve/nexis.git
- Branch:   main
- HEAD:     check `git log -1 --oneline`. Three new commits this session:
              <c3>  docs: refresh HANDOFF.md for Phase 2 step #3
              2a0831d phase 2 step #2: math:add opcode + tiny compiler for (+ 1 2)
              ac75f69 docs: VM.md + COMPILER.md spec amendments (peer-AI turns 32, 34, 35)
              (and the earlier session work above those — `git log --oneline -30`)
- Working tree clean. Verify with `git status`.

═══════════════════════════════════════════════════════════════════════
## 2. REQUIRED READING (strict order — budget ~3 hours, do NOT skip)

### 2.1 Authoritative design docs

1. PLAN.md (2,531 lines, ~75 minutes). Especially:
   - §5   Three-representations boundary (non-negotiable)
   - §6   Language semantics (truthiness, equality, nil propagation,
            primitive core list including `letfn*`)
   - §8   Value model (16-byte tagged Value, kind table, metadata matrix)
   - §9   Persistent collections (CHAMP map, 32-way vector, list, transients)
   - §10  Memory management (precise mark-sweep tracing GC — SHIPPED)
   - §11  Compiler pipeline (defines stage boundaries)
   - §12  Bytecode & ISA (companion to docs/VM.md)
   - §14  Macros & namespaces (Clojure-style; not yet implemented)
   - §19  SIMD & performance — especially §19.6 Tier 1/2 projections
            and §19.8 performance gates methodology reference
   - §20.2 Phase 1 gate (CLOSED) and Phase 2 gate spec
   - §21  Roadmap (Phase 1 complete; Phase 2 in progress at step #2)
   - §23  Hard decisions (frozen — each requires an amendment to change)
   - §24  Open questions (deliberately undecided)

2. CLOJURE-REVIEW.md — what we take, adapt, reject from Clojure.

3. **docs/COMPILER.md** (~700 lines) — Phase 2 compiler pipeline +
   per-special-form lowering. Three amendment-log entries this session:
   - §4.3: let*/loop* binding-i RHS visibility; fn* self-name binding.
   - §5.5 / §5.6 / §5.6b / §6: closure / recur / letfn* lowering.
   - §10 #2: tiny-compiler bootstrap exception note.

4. **docs/VM.md** (~1100 lines) — Phase 2 runtime: bytecode + execution
   contracts. Two amendment-log entries this session:
   - §6 / §7 / §13: range-call ABI for `call:call` / `call:tailcall` /
     `call:apply` (peer-AI turn 32).
   - §6 / §10 / §13: closure-group opcode set; raw-index operand
     convention; routine layout split; variant tables; recur on
     captured loop bindings (peer-AI turn 34, holistic review turn 35).

5. docs/SEMANTICS.md — equality, hash, numeric corner cases. Frozen.

6. docs/VALUE.md — 16-byte Value layout, Kind discriminator, HeapHeader
   spec, signed-zero/NaN matrix. Frozen.

7. docs/HEAP.md, INTERN.md, STRING.md, LIST.md, BIGNUM.md, VECTOR.md,
   CHAMP.md, TRANSIENT.md, GC.md, CODEC.md, DB.md, BENCH.md, PERF.md,
   POOL.md — per-kind specs (Phase 1 deliverables; all SHIPPED).

8. docs/NEXTOMIC.md — post-v1 Datomic-class architecture on nexis +
   emdb. Read only when Nextomic is being scoped or when a v1 decision
   might preclude it.

9. docs/FORMS.md — Phase 0 canonical Form schema.

### 2.2 Contributor + Zig references

10. AGENTS.md — contributor routing guide.

11. **ZIG-0.16.0-REFERENCE.md + ZIG-0.16.0-QUICKSTART.md — MANDATORY
    before writing any Zig.** 30+ stdlib APIs changed between 0.15
    and 0.16 in ways that silently break training-data code. See
    §6 below for the gotchas that have actually bitten us.

═══════════════════════════════════════════════════════════════════════
## 3. BUILD VERIFICATION (run on arrival)

```
cd /Users/shreeve/Data/Code/nexis
zig build test --summary all
```

Expected: **487 tests pass / 68 build steps succeed**. If the tree
isn't green, STOP and diagnose before editing.

Test breakdown at handoff time:
  Inline runtime tests (32 binaries):
   10  hash, 12  value, 9  eq, 12  intern, 26  heap,
   14  string, 19  list, 19  vector, 24  bignum, 42  hamt,
   20  transient, 30  dispatch, 16  gc, 47  codec, 15  db,
   9  pool, 21  vm (← +6 from step #2: math:add + holistic review),
   8  reader (Phase 0)
  Property tests (test/prop/, 11 files):
   7  primitive, 10  intern, 8  heap, 6  string, 8  list,
   10  bignum, 9  vector, 13  hamt, 8  transient, 3  gc, 11  codec
  Compile tests (NEW this session):
   7  compile (← step #2 tiny compiler)
  Golden reader tests:
   10  test/golden/

If you run `zig build parser` for any reason, note it requires
../nexus/bin/nexus to exist. Regenerating src/parser.zig isn't
normally needed unless you're touching nexis.grammar.

═══════════════════════════════════════════════════════════════════════
## 4. ARCHITECTURAL NARRATIVE (things docs won't teach you)

The hard-won insights from 14+ sessions of implementation. Phase 2 has
its own wrinkles on top of the Phase 1 narrative below.

### 4.1 The dispatch module is a one-way terminal (Phase 1, still true)

`src/dispatch.zig` is the central composition point for every heap-kind
operation. It imports value, eq, heap, hash, string, list, vector,
bignum, hamt, transient, db. **Nothing imports dispatch.** This
asymmetry is forced by a Zig test-runner constraint (cyclic imports
across "self" appearance violate "file in only one module" rule).

Pattern: kind modules provide per-kind operations with callback
signatures (e.g., `hashSeq(h, elementHash)`); dispatch composes them.
`value.hashImmediate` (not `hashValue`) panics on heap kinds pointing
to `dispatch.hashValue`. Same for `eq.equalImmediate` →
`dispatch.equal`. Documented in every panic message.

### 4.2 Equality-category hash domains (Phase 1, still true)

SEMANTICS.md §3.2 says cross-type sequential equality requires
`(= (list 1 2 3) [1 2 3]) → true`, which means they MUST hash the
same. Domain byte:
  - kind_local → @intFromEnum(Kind)
  - sequential (list, persistent_vector) → 0xF0 (shared)
  - associative (persistent_map) → 0xF1 (shared)
  - set (persistent_set) → 0xF2 (shared)

Chosen outside the 0..29 valid-kind range. `dispatch.eqCategory`
exhaustive test pins this for every Kind in v1.

### 4.3 The Cursor pattern for cross-kind sequential walks (Phase 1)

When vector landed (second sequential kind), `dispatch.sequentialEqual`
needed to walk list-vs-vector pairs without O(n²). Each sequential
kind exposes `Cursor { init, next }`. dispatch.zig composes them in a
`SeqCursor = union(enum) { list, vector }` and walks pairwise.
Same-kind pairs use the O(n) `equalSeq` fast paths; cross-kind uses
cursors.

### 4.4 The bignum canonicalization invariant (Phase 1)

A bignum whose magnitude fits in i48 cannot exist. Every constructor
routes through `canonicalizeToValue(heap, negative, limbs)` which
trims trailing zeros, folds zero magnitude to `fixnum(0)`, folds
fixnum-range magnitudes to fixnum, and only allocates a bignum for
genuinely-out-of-range values.

### 4.5 GC lives now (Phase 1, post-handoff change)

`src/gc.zig` is the precise mark-sweep collector. Per-kind tracing
walks heap, intern tables, transient wrappers, db. Phase 2 VM frames
will participate as additional roots; current single-frame VM's
`Frame.slots` is owned by the VM but not yet enumerated by GC because
the tests don't allocate heap objects in slots. When step #5 lands
closures (heap objects), the VM's GC integration becomes load-bearing.

### 4.6 Pool allocator (Phase 1 perf lift)

`src/pool.zig` is a 16-class size-class pool over page allocator. Default
backing for Heap. Measured 1.8–3.94× lift on collection construction
benchmarks (PERF.md §3, POOL.md). Don't bypass it without a measured
reason.

### 4.7 Phase 2: range-call ABI (peer-AI turn 32)

`call:call A=call_base B=argc C=result_slot`. Caller stages
`slot[A]=closure` and `slot[A+1..A+argc]=args` BEFORE the call.
Callee's slot 0 sources from caller's slot[A+1] (window or copy).
**Caller values live across the call MUST reside in slots strictly
below A** — the call-clobbered region. `call:tailcall` slides args
down to keep backing-stack bounded across mutual tail-recursion.

Not yet implemented (step #5). Spec is frozen in VM.md §6.

### 4.8 Phase 2: descriptor-based closure construction (peer-AI turn 34)

`closure:make A=prototype_const B=capture_descriptor C=result_slot`.
The capture set is statically known; capture sources are
compile-time metadata (a side-table per routine), NOT runtime
slot-staging. Each descriptor entry is `local_cell_slot(s)` (raw
cell pointer in caller's slot s) or `inherited_upvalue(u)` (raw
cell pointer from current closure's upvalues[u]).

The U operand kind on existing opcodes (mov, math, etc.) reads
**cell contents** via `resolve(u:N)`. NO dedicated `closure:read-upval`
opcode. Writes (`store(u:N, ...)`) are reserved (`:unsupported-write`)
until Phase 3+ dynamic-binding rebinding.

`letfn*` (PLAN §6.1 primitive core) requires `closure:new-cell` +
`closure:init-cell` placeholder cells so closures can be constructed
referring to each other before either has its final value.

**recur on captured loop bindings allocates a FRESH cell per
iteration** (NOT mutates the shared cell). Otherwise closures
created in earlier iterations would observe later iterations'
values, breaking Clojure-equivalent immutable lexical binding
semantics. The canonical hazard:

```clojure
(loop [i 0 acc []]
  (if (< i 3) (recur (+ i 1) (conj acc (fn [] i))) acc))
;; Closures must capture 0, 1, 2 — NOT 3, 3, 3.
```

Not yet implemented (step #5). Spec is frozen in VM.md §6 +
COMPILER.md §5.6 / §6 / §5.6b.

### 4.9 Three representations stay distinct (PLAN §5)

Form (parsed source, in `src/reader.zig`), Value (runtime 16-byte
tagged cells), Durable-Encoded (codec wire format, SHIPPED in
src/codec.zig). They only fuse through explicit codec ops.

### 4.10 Tiny vs reader.Form in compile.zig (step #2 ↔ step #3 boundary)

`src/compile.zig` step #2 takes a local `Tiny` representation, NOT
`reader.Form`. The public entry point is `compileTiny()` (loud
naming). When step #3 adds conditionals, the natural shape extends
to a recursive `Tiny` (with `if: struct { test: *Tiny, then: *Tiny,
else_: ?*Tiny }`), at which point real `reader.Form` integration
becomes worthwhile. Step #3 is where compile.zig grows up.

═══════════════════════════════════════════════════════════════════════
## 5. SESSION DISCIPLINE (non-negotiable — this is what makes the work good)

Every substantive module commit follows this loop. Skipping any step
has caused real bugs in earlier sessions.

### 5.1 Before writing code

1. Read the relevant frozen docs (PLAN.md §6/§11/§12, VM.md, COMPILER.md,
   plus per-kind doc if it exists).
2. Draft a strategy message to peer AI via `user-ai` MCP with
   `conversation_id: "nexis-phase-1"`. Lay out scope, representation
   options, specific questions. Don't rubber-stamp — peer AI has caught
   real bugs every single turn. Examples:
   - Turn 32: range-call ABI strategy → exposed wrong assumption about
              tailcall slide-vs-base-shift
   - Turn 34: closure-group encoding → caught 3 critical bugs (missing
              prototype operand, missing letfn* placeholders, recur
              semantic violation)
   - Turn 35: holistic review → caught 15 spec drifts across COMPILER.md
              ↔ VM.md ↔ src/vm.zig that per-turn reviews missed

### 5.2 Spec first

If the module is substantive (a new opcode group, a new dispatch
pattern, a new feature), draft the relevant doc section BEFORE the
code. Pin the frozen invariants there. Examples from this session:
  - VM.md §6 amendments landed BEFORE step #5 closure code
  - COMPILER.md §10 #2 exception note landed AFTER tiny compiler
    revealed the bootstrap-vs-folding tension

### 5.3 While writing code

- Peer AI's recommended fixes from the strategy turn get applied
  DURING implementation, not after.
- Property tests land ALONGSIDE the module, not at the end. Every
  module has a test/prop/*.zig file that exercises its invariants
  under randomized workloads. (Phase 2 is opcode-by-opcode small
  enough that property tests may not always make sense — strategy
  turn should ask peer AI.)
- Inline unit tests (test "..." blocks) cover structural invariants;
  property tests cover statistical laws.
- Use deterministic PRNG seeds: failures must reproduce.
- `std.testing.allocator` catches leaks at teardown — if your
  `deinit` path forgets something, the test trips.

### 5.4 Before commit

1. Run `zig build test --summary all`. Green = proceed.
2. Engage peer AI for a code review (discuss with the same
   conversation_id, OR use the `review` tool for a structured pass).
3. Apply peer's review items. Do NOT rubber-stamp. Previous turns
   have caught:
   - TypeError vs KindMismatch taxonomy drift (turn 33)
   - Missing test cases (negative underflow, dst aliasing) (turn 33)
   - Missing closure prototype operand in `closure:make` (turn 34)
   - recur captured-binding semantic violation (turn 34)
   - 15 doc-vs-code drifts including the recur contradiction across
     three sections (turn 35)
4. Run tests again; green.
5. `git add <files> && git commit -m "$(cat <<'EOF'\n...body...\nEOF\n)"`
6. Do NOT push to origin unless the user explicitly asks.

### 5.5 Git discipline

- Short imperative subject. Body when substantive (cite the
  SEMANTICS.md / PLAN.md / COMPILER.md / VM.md sections that govern,
  cite the peer-AI turn that caught each fix, call out explicit
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

As of this handoff, the conversation is **~35 turns deep** spanning
~14 substantive sessions. Peer AI has read every spec doc multiple
times, has seen the VM kernel implementation, has read em's RUNTIME.md
+ ISA.md for the calling-convention discussion, and has caught one or
more real bugs in nearly every turn it's been engaged.

**Continue this thread.** A new conversation_id throws away ~15 hours
of accumulated context. Peer AI's strongest contributions come from
catching drift between turns — that's only possible if it remembers
the prior commitments.

Invocation example:

  CallMcpTool server="user-ai" toolName="discuss" arguments={
    "conversation_id": "nexis-phase-1",
    "message": "...your substantive question + full context...",
    "model": "gpt-5.5",
    "attachments": [
      {"type": "file", "path": "/Users/shreeve/Data/Code/nexis/docs/VM.md"}
    ]
  }

Peer AI is GPT-5.5 by default. Attachments support file/url/blob;
attach the actual current state of files for holistic-review turns
(it'll catch drift between sessions you didn't notice).

**Pattern**: provide peer with everything they need (relevant spec
text quoted; current design proposals; specific questions; explicit
"don't rubber-stamp" instruction). A one-line question gets a
one-line answer. A substantive briefing gets a substantive critique.

═══════════════════════════════════════════════════════════════════════
## 7. CURRENT STATE — what's shipped, what's pending

### 7.1 Phase 1 (COMPLETE — all 8 gates closed per PLAN §20.2)

```
Runtime core:
  src/hash.zig        xxHash3-64 + structural combiners + mixKindDomain
  src/value.zig       16-byte tagged immediates; hashImmediate method
  src/eq.zig          identical? + equalImmediate (immediates only)
  src/intern.zig      keyword + symbol intern tables
  src/heap.zig        allocator + HeapHeader + minimal sweep scaffold
  src/dispatch.zig    one-way-terminal cross-kind composition
  src/pool.zig        size-class pool allocator (1.8–3.94× lift)

Heap kinds (all shipped):
  src/string.zig      UTF-8 strings (subkind 1: heap)
  src/bignum.zig      arbitrary-precision integers (Scope A only:
                      construction + canonical form + eq + hash;
                      arithmetic Scope B deferred to mid-Phase 2)
  src/coll/list.zig   immutable cons list + Cursor
  src/coll/rrb.zig    persistent vector (plain 32-way + tail) + Cursor
  src/coll/hamt.zig   CHAMP persistent_map + persistent_set
  src/coll/transient.zig  transient wrappers for vector/map/set

Systems (all shipped):
  src/gc.zig          precise mark-sweep with per-kind tracing
  src/codec.zig       Value ↔ bytes (LEB128/ZigZag wire format)
  src/db.zig          emdb bridge + durable-ref

Phase 0 (still in place):
  src/nexis.zig       @lang module: Tag enum + Lexer wrapper
  src/reader.zig      Sexp → Form normalizer + pretty-printer
  src/golden.zig      golden test runner
  src/parser.zig      GENERATED (do not edit; regenerate via `zig build parser`)
```

### 7.2 Phase 2 progress (in progress)

```
SHIPPED:
  [x] src/vm.zig           VM kernel (mov, call:return, math:add) per
                           VM.md §3-§4 + step #2
  [x] src/compile.zig      Tiny compiler for `(+ 1 2)` per step #2
                           (compileTiny() entry; Tiny union(enum) input;
                           arena-owned Compiled output)

PENDING per COMPILER.md §10:
  [ ] step #3   Conditionals: jump:* opcodes + `if` lowering
                NEXT — see §10 below for the immediate scope.
  [ ] step #4   Locals + let* — slot allocation, sequential bindings
  [ ] step #5   Functions + closures — range-call ABI (VM.md §6),
                closure-group opcodes (VM.md §6), backing-stack
                evolution of Frame, GC root enumeration from frames
  [ ] step #6   recur + loop* — including fresh-cell-per-iteration for
                captured bindings (VM.md §6 + COMPILER.md §5.6)
  [ ] step #7   Vars + def — namespace integration (PLAN §14.3 sketch
                exists but no docs/NAMESPACE.md or src/ns.zig yet)
  [ ] step #8   Macroexpand + syntax-quote + #%anon-fn — including
                auto-gensym hygiene (PLAN §14.2)
  [ ] step #9   try/catch/throw (VM.md §12 minimal v1 spec)
  [ ] step #10  Error-reporting hardening — SrcSpan threading
                end-to-end, structured error Value layer
  [ ] step #11  Golden + eval pipeline tests

REFACTORS LIKELY DURING THE ABOVE:
  [ ] src/numeric.zig      extract addNumbers + future math sub/mul/etc.
                           when 2nd or 3rd math op lands (peer-AI turn 33)
  [ ] src/vm/<group>.zig   split per-group handler files when vm.zig
                           crosses ~1500 LOC (it's at ~1100 now)
  [ ] backing value-stack  current Frame.slots is per-frame owned;
                           must evolve to backing-stack-with-frame-base
                           when call:call lands (VM.md §7)
  [ ] src/gc.zig hookup    VM frames as roots when closures land
```

### 7.3 Spec status

```
Frozen and authoritative:
  [x] All Phase 1 specs (HEAP, INTERN, STRING, LIST, BIGNUM, VECTOR,
      CHAMP, TRANSIENT, GC, CODEC, DB, BENCH, PERF, POOL).
  [x] FORMS.md (Phase 0 reader).
  [x] SEMANTICS.md, VALUE.md.
  [x] COMPILER.md — §1-§13 all populated; amendment log up to date
      with this session's three rounds.
  [x] VM.md — §1-§18 all populated; per-group variant tables for mov,
      call, math, closure, jump as authoritative variant numbering;
      amendment log up to date.

Spec gaps to address before their step lands:
  [ ] docs/NAMESPACE.md — Var lookup hot path, refer/alias tables.
      PLAN §14.3 has a 5-line struct sketch; needs full spec before
      step #7. ~200-300 LOC commit.
  [ ] docs/MACROS.md — macroexpander invariants; syntax-quote /
      auto-gensym contracts. PLAN §14.1-§14.2 has the contracts;
      a standalone doc would crystallize them before step #8.

Spec amendments tracked in amendment logs:
  - COMPILER.md §13: 2 entries (initial draft + 2026-05-15 §4.3
    amendments + 2026-05-15 §5/§6 closure amendments).
  - VM.md §18: 3 entries (initial + 2026-05-15 range-call ABI +
    2026-05-15 closure-group).
```

### 7.4 Phase 1 gate retirement (PLAN §20.2)

```
1. 100k+ randomized equality/hash tests        SHIPPED
2. Persistent immutability                      SHIPPED
3. Transient equivalence                        SHIPPED
4. Transient ownership                          SHIPPED
5. Codec round-trip                             SHIPPED
6. emdb round-trip                              SHIPPED
7. GC stress                                    SHIPPED
8. Interning invariants                         SHIPPED
```

### 7.5 Phase 2 gate (per COMPILER.md §9.4)

```
1. Every primitive-core form compiles + executes correctly      PENDING
   (currently only int literal + (+ int int) work via Tiny;
    real form support starts at step #3)
2. recur in 10k-iter loop runs in constant stack space          PENDING
3. Closure capture works across deeply-nested fns               PENDING
4. syntax-quote / unquote / unquote-splicing produce equivalent PENDING
   structurally-equal Forms to hand-coded equivalents
5. Compiler errors report stable error-kind keyword + primary   PENDING
   SrcSpan + macro origin when applicable
6. All golden tests pass; full test suite remains 487/487+      ON TRACK
   (487/487 currently; +14 expected from compile-golden tests)
7. bench/compiler.zig measures compilation throughput, eval     PENDING
   throughput, closure-creation cost, recur per-iter cost
```

═══════════════════════════════════════════════════════════════════════
## 8. NON-NEGOTIABLE DISCIPLINE

From PLAN.md §"Start here" and accumulated hard lessons:

1. **Three representations stay distinct** (§5). Form, Value,
   Durable Encoded are separate. They only fuse through explicit
   codec ops. Violating this is how language projects turn into
   tar pits.

2. **Respect PLAN §23 frozen decisions.** 38 decisions committed
   before code was written. Each requires a PLAN amendment with
   stated rationale to change. SEMANTICS.md §2.2 / §3.2,
   COMPILER.md §4.3 / §5/§6, VM.md §6 / §10 / §11 / §13 have all
   been amended during Phase 1-2 to fix real contradictions —
   that's the channel. Do not silently deviate.

3. **Read actual source, don't trust intuition.**
   - For Clojure behavior: grep `misc/clojure/src/jvm/clojure/lang/`.
     The Java core is checked in. AIs have twice confidently written
     wrong claims about Clojure and only caught them by opening
     LispReader.java / PersistentVector.java and reading the bytes.
   - For Zig 0.16 APIs: read from /opt/homebrew/Cellar/zig/0.16.0/lib/
     zig/std/. Training-data code for Zig 0.15 silently breaks.
   - For em's bytecode/runtime patterns: ../em/docs/architecture/
     ISA.md and RUNTIME.md are the references; the nexis VM is
     em-template-shaped per PLAN §12.

4. **Do NOT widen the v1 non-goals list** (§4) without an amendment.

5. **Do NOT expose benchmarks publicly** until Phase 6 has real
   numbers (§19.7). The plan intentionally under-promises and
   over-delivers. BENCH.md pins the methodology — every performance
   claim must satisfy numerical + accurate + fair + relevant.

6. **Honesty clause** (from BENCH.md §8): when benchmarks eventually
   ship, publish scenarios where Clojure wins. Manufactured
   symmetry is worse than admitted losses. External Clojure-
   practitioner review required before any comparative report.

7. **Hand-trace before code** for substantial design questions.
   Two hand-traces this session ((defn fact ...) and
   (defn make-adder ...)) surfaced spec holes that step #5 would
   have hit; they cost ~1 hour each and saved days of rework.

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
- Unused locals must be `const`, not `var`.
- Multi-char literals in grammar rules: `nexus` generator's token
  name "integer" is hardcoded in the number scanner; `hasIdent`
  dispatch only fires when token name is literally "ident".
- **Packed structs have field-order layout**. `vm.Inst` and
  `vm.Operand` rely on this; if you add fields, mind the bit order.

═══════════════════════════════════════════════════════════════════════
## 10. IMMEDIATE NEXT TASK — Phase 2 step #3 (conditionals)

Per COMPILER.md §10 #3: add `jump:*` opcodes + `if` lowering.

### Scope

**VM-side (`src/vm.zig`)**:
- `Jump` enum with variants per VM.md §10.5: `jmp`, `if_true`,
  `if_false`. (J operand kind already exists in OpKind.)
- `execJump` handler dispatching on variant.
- `jump:if-true` / `jump:if-false` need a "is this value falsy?"
  predicate. Per PLAN §6.2: only nil and false are falsy. Per
  peer-AI turn 35, this predicate should live in `value.zig` or a
  shared helper (the macroexpander/analyzer constant-folding will
  want the same semantics) — likely `value_mod.isFalsy(v)` returning
  `v.kind() == .nil or v.kind() == .false_`.
- `asm_.jumpJmp` / `asm_.jumpIfTrue` / `asm_.jumpIfFalse` helpers.
- New tests for each variant + branch-not-taken, branch-taken,
  out-of-range jump target, the truthy/falsy edge cases (0, "",
  empty collections — all truthy per §6.2).

**Compiler-side (`src/compile.zig`)**:
- Extend `Tiny` with an `if` variant: `if: struct { test: *Tiny,
  then: *Tiny, else_: ?*Tiny }`. Test/then/else_ are heap-allocated
  Tiny pointers — Tiny becomes recursive. The `compileTiny()` arena
  owns them.
- Implement `compileIf` per COMPILER.md §5.2:
  - Lower test into a slot.
  - Emit `jump:if-false` to else-label.
  - Emit then code, leaving result in dst.
  - Emit `jump:jmp` to end-label.
  - Emit else-label, else code (or `mov:load-nil` if absent).
  - End-label.
- `compileTiny` may want to evolve into a "compile-to-destination"
  API per peer-AI turn 35 recommendation:
    `fn compileExpr(form: *const Tiny, dst: u12, emitter: *Emitter) !void`
  This sets the pattern that step #4 (let*) will need for slot
  allocation. Worth proposing in the strategy turn.
- New compile tests: `(if true 1 2)` = 1, `(if false 1 2)` = 2,
  `(if nil 1 2)` = 2, `(if 0 1 2)` = 1 (truthy), `(if "" 1 2)` = 1
  (truthy), `(if true 1)` = 1 (no else), `(if false 1)` = nil.

### Strategy turn (DO THIS FIRST)

Before writing code, draft a peer-AI strategy message on
`conversation_id: "nexis-phase-1"` covering:

1. **Compile-to-destination vs return-from-compile pattern**: peer AI
   suggested `compileExpr(form, dst, emitter)` over the current
   `compile(form) -> Compiled` shape. The current shape works for
   step #2 because there's only one form per Compiled; step #3's `if`
   needs to compile two arms targeting the same dst. Should the API
   shift now (small refactor, sets the pattern early) or in step #4?

2. **Tiny representation**: recursive Tiny needs an arena. Currently
   compileTiny accepts a pass-by-value `Tiny`. Should the test
   fixtures construct trees through a small builder, or hand-build
   them with `&Tiny{...}`?

3. **isFalsy predicate location**: value.zig vs vm.zig vs new
   value-helpers module. Worth ~1 turn of peer review because every
   subsequent opcode that branches on truthiness will reference it.

4. **Emitter abstraction**: as Tiny grows, the current "alloc one
   array up front" pattern stops scaling. Should an Emitter struct
   land now (build code into an ArrayList, then ToOwnedSlice at
   end) or stay with current shape?

These are the four design choices step #3 actually requires. Most
of the rest is mechanical.

### Estimated scope

- ~150 LOC in src/vm.zig (Jump enum, execJump, helpers, tests)
- ~100 LOC in src/compile.zig (Tiny.if, compileIf, tests)
- ~10-15 new tests across both
- ~30 minutes of strategy + review
- Likely 1-2 sessions if done with peer AI engagement and code review

### After step #3 ships

Step #4 (locals + let*) becomes the obvious next item per
COMPILER.md §10. let* is where slot allocation gets non-trivial
(scoped lifetimes; sequential bindings per the §4.3 amendment).
The Tiny representation likely grows a `let_star` variant; compile.zig
gains a slot allocator (probably starting with bump-allocate per
binding, no liveness reuse — that's Phase 6 polish).

═══════════════════════════════════════════════════════════════════════
## 11. THE QUALITY BAR — what makes this project world-class vs just competent

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
  - **Internally consistent** — the SEMANTICS.md / VM.md / COMPILER.md
    chain has no silent contradictions. When we find one (the
    recur-on-captured-loop-binding contradiction across three
    sections caught by the holistic-review turn), we amend the spec,
    not paper over the code.
  - **Tested at the right level** — 487 gates today, scaling to
    100k+ randomized iterations across all property test files.
    Every invariant has a property-test retirement receipt or an
    explicit "tested by example only because it's a unique case"
    annotation.
  - **Benchmarked honestly** — BENCH.md §11's summary sentence:
    "We measured several clearly defined performance regimes,
    with published source and methodology, and here is where
    nexis is faster, where it is comparable, and where Clojure
    wins." No report that can't survive that sentence ships.
  - **Spec-first, not code-first** — every frozen invariant
    lands in a doc BEFORE code can violate it. Amendments happen
    through PR-style doc edits, not commit messages.
  - **Honest about progress** — Phase 1's previous-AI handoff was
    blunt about the ~35% → ~55% risk-weighted progress vs ~60% →
    ~70% LOC-weighted. Don't conflate "shipped foundation" with
    "retired project risk." Phase 2 is at step #2 of 11; we are
    early.

### 11.3 What breaks the quality bar

- Writing code before drafting the spec for a substantive module.
- Skipping peer AI strategy turn ("this is obviously right" is
  usually when it isn't — see turn 34 catching three load-bearing
  bugs in what felt like a "consistency" proposal).
- Skipping peer AI code review ("I'll just commit and let CI catch
  it" — there is no CI; you ARE the CI).
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
- Skipping the holistic-review pass when several pieces have
  landed. Per-turn reviews catch local bugs; holistic reviews
  catch drift between pieces. The session that ended at this
  handoff caught 15 such drifts in a single holistic turn.

### 11.4 Final word

What made this session work across 3 commits + 4 peer-AI turns:
  - **Hand-trace before code** for substantial design questions.
    The (defn fact ...) trace caught the let*/loop* binding-i
    visibility ambiguity before any line of resolver code was
    written. The (defn make-adder ...) trace caught the closure-
    descriptor encoding question before any line of closure code
    was written. Both took ~30 minutes; both saved weeks of
    rework downstream.
  - **Peer AI as a peer, not a rubber stamp.** Turn 34 caught three
    critical bugs in my own proposal — the missing routine operand,
    the missing letfn* placeholders, the recur semantic violation.
    Turn 35 caught 15 spec drifts across the integrated result.
    Each per-turn review caught specific items; only the holistic
    turn caught drift between turns.
  - **Spec-first, with frozen invariants.** Every COMPILER.md /
    VM.md amendment landed before any code that depended on it.
    The amendment log entries cite the peer-AI turn that drove
    them; the commit message cites both. This makes future
    debugging tractable.
  - **Honest reporting.** When peer AI catches a bug, name it as
    a bug. When a spec contradiction exists, amend the spec rather
    than paper over with a code workaround. When work is complete,
    say so; when it's deferred, say so explicitly.

Phase 2 gate (COMPILER.md §9.4) is the next major milestone.
Don't rush it. Plan for slack.

The force remains with you.

═══════════════════════════════════════════════════════════════════════
## 12. WHAT TO DO IN YOUR FIRST MESSAGE

1. Run `git log --oneline -10` and `git status`. Confirm you're at
   the most recent commit on a clean main.
2. Run `zig build test --summary all`. Confirm 487 tests, 68 build
   steps, all green.
3. Read PLAN.md (75 min). Do not skim §6, §11, §12, §14, §20.2,
   §21, §23.
4. Read at minimum: AGENTS.md, ZIG-0.16.0-REFERENCE.md, docs/VM.md,
   docs/COMPILER.md, docs/SEMANTICS.md, docs/VALUE.md.
5. Post a short status summary:
   - What you read.
   - Build status with exact test count.
   - Proposed next module (default: step #3 conditionals per §10
     above; argue for whichever you prefer with reasons).
   - Any clarifying questions.
6. After user confirms, engage peer AI via `user-ai` MCP with
   `conversation_id: "nexis-phase-1"` for a strategy check on
   step #3 (the four design questions in §10 above) BEFORE writing
   code.

Good luck. Every commit you ship is already being reviewed by
peer AI, by the user, and by the quality bar in §11. Hold the
line.
```

---

A few notes about the handoff mechanics:

- **Conversation thread**: `conversation_id: "nexis-phase-1"` is now ~35 turns and ~14 sessions deep. Peer AI will remember everything we've discussed, including specific corrections it has made (turn 33's KindMismatch alignment, turn 34's three closure bugs, turn 35's 15 drifts). This is enormous accumulated context — preserving it is high-leverage.
- **Test count**: `487/487 tests, 68 build steps` is the ground truth for "clean starting state."
- **Phase 2 step #2 boundary**: the tiny `compile.zig` exists but is intentionally limited. Step #3 is where it grows up to handle real Form-tree shapes (or extends `Tiny` recursively, depending on what the strategy turn decides).
- **Spec convergence**: COMPILER.md and VM.md are now the load-bearing contracts for steps #3-#11. The amendment logs in each cite the peer-AI turn that drove each change.
- **Hand-trace discipline**: two hand-traces this session caught spec holes that would have manifested as bugs in step #5. Recommend the next AI do at least one before any non-trivial step (probably step #5 itself, since closures are the most novel design surface).
