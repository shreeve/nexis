# nexis Phase 5 — Handoff Prompt (write this to the next AI as your first message)

```
You are taking over work on the nexis project — a modern, Zig-native Lisp
inspired by Clojure, built for persistent data, durable identity, and
world-class performance. Multi-phase implementation driven by PLAN.md at
the repository root.

============================================================
PHASES 0–4 ALL COMPLETE. Currently in Phase 5 (Clojure
compatibility breadth: atoms, strings/IO, protocols, more
stdlib). Pre-Phase-5 work is ALREADY DONE — see below for
state + roadmap.
============================================================

Phase 0  — reader + Form normalization                  ✅ SHIPPED
Phase 1  — runtime: Value model, CHAMP/RRB/list, GC,
           codec, emdb integration                       ✅ SHIPPED
Phase 2  — compiler + bytecode VM                        ✅ SHIPPED
Phase 3  — macros, namespaces, REPL, stdlib infra,
           multi-namespace, destructuring, multi-arity
           defn, require                                 ✅ SHIPPED (3.6 done; 3.7 deferred)
Phase 4  — DURABLE IDENTITY as first-class language
           concept (durable_ref + with-tx + db/alter! +
           db/scan + db/reduce-tree + snapshots)         ✅ SHIPPED — Phase 4 EXIT MET
Phase 5  — Clojure compatibility breadth                 ← IN PROGRESS

The LANGUAGE is feature-complete for v1's promised core: every
primitive form, host macros, user defmacro, syntax-quote with
auto-gensym, try/catch/finally with catchable VmErrors, ~30
native fns (sequence/HOF/arithmetic/collection), multi-namespace
with require + qualified symbols, full destructuring +
multi-arity defn + composite core.nx layer.

THE OTHER BIG ARC IS ALSO DONE: durable refs backed by emdb
(LMDB-class B+ tree, MVCC). `(db/open "app.edb")` → refs that
PERSIST across processes, with `(with-tx [tx conn] ...)` atomic
multi-write transactions, exception-rollback verified,
time-travel via MVCC snapshots. Single binary. No JVM.
The pitch ("Clojure + Datomic, fused") is no longer
aspirational — it's runnable in examples/todo-app.nx.

THIS HANDOFF prepares you for Phase 5: closing the "yes you
can run real Clojure-style code" gap. The architectural
hard work is DONE; what's left is breadth + a few specific
new abstractions (protocols + records is the biggest).

563 phase2 + 86 reader/golden = 649 tests in the fast inner-
loop suite (~3s). Full suite (`zig build test`) green including
Phase 1 randomized property tests.

Read this entire prompt before touching anything.

═══════════════════════════════════════════════════════════════════════
## 1. REPOSITORY

- Location: /Users/shreeve/Data/Code/nexis/
- Remote:   git@github.com:shreeve/nexis.git
- Branch:   main
- HEAD:     check `git log -1 --oneline`. Recent commit chain
            (newest first; ~3 dozen Phase-3+ commits):

              == Phase 4 (durable identity) ==
              8189bf8 phase 4.0f: snapshot vocabulary — TIME TRAVEL
              d3b2412 phase 4.0e: persistent to-do tracker — Phase 4 EXIT MET
              0c3c959 phase 4.0d: db/scan + db/reduce-tree
              0807b5d phase 4.0c: @deref + db/alter!
              bc21a0a phase 4.0b: with-tx / with-read-tx + tx-threaded ops
              e64c091 phase 4.0a: durable refs backed by emdb

              == Phase 3 (language core) ==
              a1e23c4 phase 3.6: require + file loading + :as aliases
              e5639d8 phase 3.5b: multi-arity defn
              0fe09fa phase 3.5a: destructuring in let / fn / defn params
              83f8e85 phase 3.4: multi-namespace (registry + qualified symbols + ns)
              d36b745 phase 3.3d: embedded core.nx composite stdlib layer
              d596f57 phase 3.3c: collection utilities
              60af4d8 phase 3.3b: VM.callValue + apply + HOFs + first-class arithmetic
              e003aad phase 3.3a: native_fn infra + 10 macro-authoring primitives
              ce534d1 phase 3.2: user-defined defmacro with compile-time VM eval
              8461ae9 phase 3.1: maps + sets as runtime values
              9364615 phase 3.0c: catchable VmErrors
              7d8a16e phase 3.0b: anon-fn `#(...)` reader-macro expansion
              4ccd281 phase 3.0a: REPL (bin/nexis repl)

              == Phase 2 (compiler + VM) — see `git log --oneline` ==

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
   - §21  Roadmap (Phases 1-2 complete; Phase 3.0 complete; Phase 3.1+ pending)
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

11. **ZIG-0.16.0.md — MANDATORY
    before writing any Zig.** 30+ stdlib APIs changed between 0.15
    and 0.16 in ways that silently break training-data code. See
    §6 below for the gotchas that have actually bitten us.

═══════════════════════════════════════════════════════════════════════
## 3. BUILD VERIFICATION (run on arrival)

**Two build steps; use the right one for the right loop.**

For **inner-loop iteration** (~3 seconds):
```
cd /Users/shreeve/Data/Code/nexis
zig build phase2-test
```
Runs vm + compile + expand + stdlib + loader + integration +
property tests. Expected at HEAD `8189bf8`:
  95 vm + 322 compile + 6 macro-prop + 2 stdlib + 1 loader +
  4 closure-prop + 133 integration = **563 tests pass**.

For **pre-commit validation** (~3 minutes, ~1 GB peak):
```
cd /Users/shreeve/Data/Code/nexis
zig build test --summary all
```
Runs the full Phase 0/1/2 suite + randomized property tests.
The ~3 min runtime is dominated by Phase 1's randomized HAMT
gate (~100k ops, can OOM-kill on memory-constrained systems
— use `phase2-test` for inner-loop if that bites).

For **end-to-end smoke** (verify Phase 4 actually persists):
```
cd /tmp && rm -f todos.edb
/path/to/bin/nexis run /path/to/examples/todo-app.nx
/path/to/bin/nexis run /path/to/examples/todo-app.nx
```
Second run should show `:completed 1` — state PERSISTS.

If anything is red, STOP and diagnose before editing.

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

### 4.10 Tiny IR + Form frontend (post-step-#7)

`src/compile.zig` accepts BOTH inputs:

- **`compileTiny()` / `compileTinyWithNamespace()`** — Tiny IR
  trees built by hand. The original interface; 135 backend
  regression tests use this path.
- **`compileForm()` / `compileFormWithNamespace()`** — reader.Form
  trees produced by the reader. Goes through `lowerForm()` which
  translates Form → Tiny, then dispatches to the backend.
- **`compileSource()` / `compileSourceWithNamespace()`** — raw
  source bytes. Composes `parser.parseForm` +
  `Reader.readOneForm` + `compileFormWithNamespace`. ~85
  end-to-end tests exercise this path.

The architecture per peer-AI turn 51 (the "load-bearing" decision
for step #7): **Tiny IS the IR**. There is no parallel Form-to-
bytecode codegen path. The Form frontend is purely lowering;
the proven backend (capture pre-analysis, RecurTarget threading,
variadic rest, Var fall-through, defn placeholder cells, etc.)
takes over unchanged from Tiny.

Why this matters for future work: when adding a new special form
or improving codegen, work in the Tiny backend — that automatically
benefits both Tiny-built tests and Form-built source tests. Adding
new Form syntax means: extend the reader (if needed), add a
`lower*` function, dispatch from `lowerList`, write source-string
tests. The backend usually doesn't change.

Tiny is the long-term IR shape (eventually renamed to "Core" or
"IR" per peer-AI turn 51 §Q1 footnote); the bootstrap tests stay
indefinitely as regression coverage.

### 4.11 Capture analysis is pre-analysis, NOT lazy boxing
(peer-AI turn 44 caught the lazy-boxing control-flow bug)

The compiler's capture model is **pre-analysis with binding-time
boxing**, NOT lazy boxing. For each let* binding and each fn*
param, the analyzer walks the rest of the form looking for
descendant `fn_star` bodies that reference the binding's name.
If any do, the compiler emits `closure:box-local` UNCONDITIONALLY
in straight-line prelude code (before any branching), and the
binding is registered as `.cell_slot`.

The lazy-boxing approach (emit box-local at the moment of
capture discovery) was tried during 5b development. It is NOT
control-flow safe: if a closure capturing the binding lives in
an unreachable branch (e.g., `(if false (fn* [] x) 0)`), the
box-local instruction lives in dead code and never executes at
runtime, but the compiler's scope thinks the binding is boxed.
Subsequent same-frame reads would emit `closure:get-cell`
against an unboxed slot → runtime `:expected-cell` trap on
perfectly valid programs.

The pre-analysis pivot in 5b made the binding representation
(`.direct_slot` vs `.cell_slot`) provably stable across ALL
control-flow paths. `BindingRef` is immutable from binding-time
onward; no mid-codegen mutation. The captured-loop-binding
fresh-cell semantics (5d) and captured-fn-param semantics (5e)
both rely on this invariant.

### 4.12 LowerEnv tracks lexical names for intrinsic shadowing only
(peer-AI turns 51 / 53 / 54; #7b-#7d wired)

The Form-frontend has its OWN lexical environment (`LowerEnv` in
compile.zig), entirely separate from the backend's `Emitter.scope`.
LowerEnv exists for ONE purpose: deciding whether to inline
intrinsics (`+`, `<`) or fall through to ordinary call lowering.

Two categories of operator-position symbols:

- **Special forms** (`if`, `do`, `let*`, `fn*`, `letfn*`,
  `loop*`, `recur`, `quote`, `def`, `defn`, `var`) — RESERVED.
  Recognized regardless of any lexical binding with the same
  name. `(let* [if 1] (if true 2 3))` → 2 (the inner `if` is
  still the special form).
- **Inlineable intrinsics** (`+`, `<` in #7b) — SHADOWABLE.
  Check `env.contains(name)` before inlining; if shadowed,
  fall through to ordinary call. `(let* [+ (fn* [a b] 42)]
  (+ 1 2))` → 42 (NOT 3 — `+` is shadowed).

LowerEnv is sequential: each `let*`/`loop*` binding's RHS sees
only PRIOR bindings (matches Tiny semantics, peer-AI turn 35).
Body sees all. fn*/defn body env adds params + rest + self-name.
letfn* uses two-pass lowering — all binding names in shared env
FIRST, then each fn body sees that env + its own params.

**Critical correctness trap** documented at peer-AI turn 53 §
"Critical trap": LowerEnv must mirror lexical visibility
exactly for these inlining decisions. Tests pin every shadowing
scenario (params shadow, letfn names shadow, def does NOT
shadow — see below).

**Documented staged limitation**: namespace-level Var shadowing
is NOT handled. `(do (def + (fn* [a b] 42)) (+ 1 2))` still
inlines to 3 because LowerEnv only tracks lexical names, not
namespace Vars. Test `"compile #7: STAGED LIMITATION"` pins
this. Fixing requires LowerEnv to consult the namespace at
lowering time — Phase 3+ refinement.

LowerEnv is NOT slot resolution. Slot resolution happens in the
backend via `Emitter.resolveOrCapture` after lowering. The two
envs run independently; they happen to track the same shape of
name set, but for entirely different purposes.

### 4.13 Vars are heap-allocated identity-stable cells
(peer-AI turn 49 design; #6a/#6b/#6c shipped)

A `Var` is `{ name, root, bound, meta }`. Owned by a `Namespace`
which maps `name → *Var`. The VM owns one global `Namespace`
lazily via `ensureNamespace()`; multi-namespace machinery is a
later commit.

`Var` is a value-kind (`.var_ = 25` per VALUE.md) but encoded
in the staged raw-pointer-in-payload style (same as Closure
and UpvalCell) — when GC migration lands, all three migrate
together to `heap.alloc(.kind, ...)` with `*HeapHeader` payloads.

**Identity-stable rebind**: `(def x 5)` then `(def x 10)` updates
the SAME Var in place. Existing closures that captured `x` via
the namespace fall-through (`var:load-var`) see the new value
on next read. Tests verify this directly.

**Forward references** work because Vars can be interned unbound
(`bound = false`). The compiler creates the Var at compile time
(symbol fall-through OR explicit def), but reading the Var's
root traps `:unbound-var` until a `def` sets it. The trap fires
only on actual invocation, not on compilation.

**Per-routine `var_table`** holds `*Var` pointers; the V operand
index resolves through this table at runtime. Dedup via linear
scan in `addVarRef` (var_tables are small in practice).
`Routine.var_table` propagates through `Compiled.toRoutine` and
`compileFn`'s child routine construction.


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
  src/coll/vector.zig persistent vector (plain 32-way + tail) + Cursor
  src/coll/champ.zig  CHAMP persistent_map + persistent_set
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

### 7.2 Phase 2 progress (COMPLETE — historical detail)

**Status: all 7 gate items + 11 sub-steps SHIPPED.** Brief
history below for context only; new work doesn't need to
re-litigate any of this.

```
ALL STEPS SHIPPED (COMPILER.md §10's 11-step plan):
  [x] step #1  VM kernel (mov:move, load-const, load-nil/true/false,
               call:return, return-nil) — 6 core opcodes.
  [x] step #2  math:add opcode + Tiny.add + literal-pair peephole.
  [x] step #3  Conditionals: jump:* (jmp/if-true/if-false) +
               Tiny.if_ + compileIf with back-patching.
  [x] step #4  Locals + let* — Tiny.let_star + compileLetStar with
               sequential RHS visibility, shadowing, do form.
  [x] step #5  Functions + closures (decomposed for safety):
       [x] 5a0   Backing-stack Frame refactor (base_slot + slot_count
                 windowing into VM.stack; needed for call:call).
       [x] 5a0.5 Typed Const pool (vm.Const = union { value, routine }).
       [x] 5a1   Empty-capture closures + call:call/return:
                 range-call ABI per VM.md §6.
       [x] 5b    Capture machinery — pre-analysis + cell ops +
                 U-operand. CONTROL-FLOW SAFE (peer-AI turn 44
                 caught the lazy-boxing bug; pivoted to pre-
                 analysis with binding-time closure:box-local).
       [x] 5c    Placeholder cells (closure:new-cell, init-cell) +
                 letfn* mutual recursion + named fn* self-reference.
       [x] 5d    Tail-position machinery: loop* + recur with
                 captured-fresh-cell semantics + cmp:lt + VM high-
                 water instrumentation. 10k-iter constant-stack
                 verified. call:tailcall DEFERRED per peer-AI turn 47.
       [x] 5e    Variadic params (& rest) via VM-side rest
                 construction (Option D per peer-AI turn 49).
                 Variadic-recur rejected as UnsupportedFeature.
  [x] step #6  Vars / def / namespaces (decomposed for safety):
       [x] 6a    Var struct + Namespace + var:load-var opcode +
                 UnboundVar trap.
       [x] 6b    def + var:store-var + var:var-object +
                 compileSymbol fall-through to namespace Vars.
       [x] 6c    defn sugar + forward references (compile then bind,
                 runtime traps :unbound-var only on actual
                 invocation).
  [x] step #7  Replace Tiny AST with reader.Form input. Per peer-
               AI turn 51: Form→Tiny LOWERING layer, not a
               parallel codegen path. Tiny remains the IR; the
               proven backend takes over after lowerForm. (4
               sub-commits + 1 review-fixes commit.)
       [x] 7a    Form→Tiny scaffolding + literals + symbols +
                 compileSource() end-to-end. First time real
                 `.nx` source compiles through the whole pipeline.
       [x] 7b    List dispatch + ordinary calls + special forms
                 (do/if/quote-of-scalar) + intrinsics (+/<) with
                 LowerEnv lexical-shadowing guard. New errors:
                 MalformedForm, ExpectedSymbol, ExpectedVector,
                 ReaderFailure.
       [x] 7c    Binding/fn forms via Form (let*/fn*/letfn*/loop*/
                 recur). Implicit-do for multi-form bodies. `&`
                 rest detection in parseParams. Optional self-name
                 detection in lowerFnStar.
       [x] 7d    Vars (def/defn/var) via Form. Canonical defn
                 forward-reference end-to-end via source:
                 (do (defn f [] (g)) (defn g [] 42) (f)) => 42.

  [x] step #8a-c  Macroexpand + syntax-quote + collection
                  literals + auto-gensym hygiene.
  [x] step #9.1/.2  try/catch/throw + finally.
  [x] step #10.0  SrcSpan threading in compile errors.
  [x] step #11   Golden + eval pipeline integration tests
                 (46 cases).
  [x] gate A   Property tests (3, 4, 7) + bench/main.zig.

All Phase 2 work merged. Phase 3 + 4 built on top WITHOUT
reshaping the Phase 2 architecture.

OPTIONAL / DEFERRED (decided explicitly, not blockers):
  [ ] call:tailcall opcode — context propagation differs from
      recur's; deferred per peer-AI turn 47. When it lands, must
      also perform variadic-rest construction after sliding args
      (noted in VM.md §6 amendment log for 5e).
  [ ] Variadic recur — rejected as UnsupportedFeature by
      compileRecur for variadic fn targets. Proper lowering
      rebuilds the rest list per iteration; deferred per peer-AI
      turn 49.
  [ ] letfn* with rest param — Tiny.FnBinding shape predates 5e's
      variadic support. Rejected as UnsupportedFeature in #7c;
      proper fix extends FnBinding (later commit).
  [ ] Var-aware intrinsic shadowing — (do (def + f) (+ 1 2))
      still inlines to 3 because LowerEnv only tracks lexical
      names. Lexical-only is the must-have; Var-aware is a
      Phase 3+ refinement. Pinned by an explicit
      "STAGED LIMITATION" test (peer-AI turn 54).

REPO CLEANUP DONE THIS PHASE (peer-AI turn 52 POLS audit):
  [x] notes.txt deleted (obsolete scratch note).
  [x] test/unit/ + test/bench/ empty dirs removed.
  [x] Explanatory READMEs added to test/, test/fuzz/,
      test/integration/, examples/, stdlib/.
  [x] docs/README.md module ↔ spec map added.
  [x] README.md overhauled with honest "Clojure on Zig" pitch,
      post-#7 source examples, "permanent vs phase-gated" gap
      analysis.
  [x] src/coll/hamt.zig renamed to src/coll/champ.zig (matches
      docs/CHAMP.md); src/coll/rrb.zig renamed to
      src/coll/vector.zig (matches docs/VECTOR.md). 260+ import/
      reference updates across 23 files.
  [x] ZIG-0.16.0-REFERENCE.md + ZIG-0.16.0-QUICKSTART.md
      consolidated to ZIG-0.16.0.md.

REFACTORS LIKELY DURING #8+:
  [ ] src/expand.zig  new module; recursive-to-fixed-point
                           macro expander. Will sit between
                           src/reader.zig and src/compile.zig.
                           Per CLOJURE-REVIEW.md §1.1 two-stage
                           bootstrap (trivial renaming macros
                           first; redefine with destructuring
                           later via core.nx).
  [ ] src/compile/         likely split target after #8 grows
                           compile.zig past 7k LOC: extract
                           form.zig + emitter.zig + analysis.zig
                           around the natural boundary the Form
                           frontend created. NOT urgent.
  [ ] src/vm/<group>.zig   split per-group handler files when
                           vm.zig crosses ~5000 LOC (~4400 now).
  [ ] src/gc.zig hookup    VM frames + namespace + heap as roots
                           when GC migration lands. Closure/cell/
                           Var raw-pointer-in-payload encoding
                           migrates to *HeapHeader at that time.
```

### 7.3 Spec status

```
Frozen and authoritative:
  [x] All Phase 1 specs (HEAP, INTERN, STRING, LIST, BIGNUM, VECTOR,
      CHAMP, TRANSIENT, GC, CODEC, DB, BENCH, PERF, POOL).
  [x] FORMS.md (Phase 0 reader).
  [x] SEMANTICS.md, VALUE.md.
  [x] COMPILER.md — §1-§13 all populated; amendment log up to date
      through step #6c (peer-AI turns 28, 32, 34, 35, 40, 44, 45,
      46, 47, 48, 49, 50).
  [x] VM.md — §1-§18 all populated; per-group variant tables for
      mov, cmp, math, call, closure, jump, var as authoritative
      variant numbering; amendment log up to date through step 5e
      (peer-AI turns 28, 32, 34, 40, 44, 47, 48, 49, 50).

Spec gaps to address before their step lands:
  [ ] docs/NAMESPACE.md — full Namespace spec: refer/alias tables,
      Var-table dedup discipline, multi-ns design. PLAN §14.3 has
      a 5-line sketch; #6a/#6b/#6c shipped a working single-ns
      implementation but the spec hasn't been formalized. Worth a
      doc before multi-ns work begins.
  [ ] docs/MACROS.md — macroexpander invariants; syntax-quote /
      auto-gensym contracts. PLAN §14.1-§14.2 has the contracts;
      a standalone doc would crystallize them before step #8.
  [ ] Spec text for cmp group (currently only amendment-log mention).
      Worth a §10.X subsection in VM.md when more cmp variants land.

Spec amendments tracked in amendment logs:
  - COMPILER.md §13: 10 entries (initial + §4.3 + §5.5/§5.6/§6 +
    §6.1 pre-analysis pivot + §5.5/§5.6b 5c + §5.6/§5.7 5d +
    §5.5/§6 5e + §4.1/§5 step #7 Form frontend with sub-step
    breakdown + LowerEnv staged-limitations + unsupported-Form-
    datum table).
  - VM.md §18: 8 entries (initial + range-call ABI + closure-group
    + lazy→pre-analysis revert + new-cell/init-cell wiring + cmp
    + recur runtime + variadic rest construction). Step #7 did
    not touch the VM (Form lowering produces existing Tiny which
    compiles to existing bytecode).
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

### 7.5 Phase 2 gate (per COMPILER.md §9.4) — ALL CLOSED

```
1. Every primitive-core form compiles + executes correctly      ✅ SHIPPED
2. recur in 10k-iter loop runs in constant stack space          ✅ SHIPPED
3. Closure capture works across deeply-nested fns               ✅ SHIPPED
4. syntax-quote / unquote / splicing                            ✅ SHIPPED
5. Compiler errors report kind + SrcSpan + macro origin         ✅ SHIPPED (#10.0)
6. All golden tests pass; full test suite remains green         ✅ 649 tests
7. bench/compiler.zig measures throughput                       ✅ SHIPPED (b948ab0)
```

### 7.6 Phase 3 + 4 status — all shipped except 3.7 (deferred)

```
PHASE 3 — language breadth                  ✅ COMPLETE (3.7 deferred)
  3.0a REPL + 3.0b anon-fn + 3.0c catchable VmErrors
  3.1 maps/sets as literals
  3.2 user defmacro with compile-time VM eval
  3.3a/b/c/d native_fn + HOFs + collections + core.nx layer
  3.4 multi-namespace + (ns NAME) + qualified symbols
  3.5a/b destructuring + multi-arity defn
  3.6 require + :as aliases + file loading

  Deferred (Phase 5+):
    3.7 ^:dynamic Vars + (binding ...) — peer-AI turn 71:
        defer until concrete need surfaces.

PHASE 4 — durable identity                  ✅ COMPLETE
  4.0a Connection + durable_ref + auto-ephemeral primitives
  4.0b with-tx / with-read-tx + WriteTxn/ReadTxn + tx-threaded ops
  4.0c @deref operator + db/alter! read-modify-write
  4.0d db/scan + db/reduce-tree
  4.0e examples/todo-app.nx — Phase 4 EXIT CRITERION MET
  4.0f snapshot vocabulary (db/snapshot + with-snapshot) —
       time travel verified

  Phase 4 substantive deferral:
    db/as-of "database as a value" abstraction (PLAN.md §15.7
    Datomic-style ambient snapshot context). Would need new
    Kind.db_value + ambient-context dispatch in all deref/get
    ops. Substrate is sufficient for explicit-snapshot use.
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
## 10. IMMEDIATE NEXT TASK — Phase 5: close the "runs Clojure code" gap

Per the architectural assessment at end of Phase 4, the
remaining work to make a typical Clojure-style program
(modulo Java interop) runnable on nexis is **bounded and
well-understood**. Six items, with peer-AI design pins
locked in turn 74:

| # | Item | Effort | New ground? |
|---|---|---|---|
| 1 | Atoms (`atom`/`swap!`/`reset!`/`@a`) | ~1 session | NO — small native fn arc |
| 2 | Strings as first-class + basic I/O | ~2 sessions | NO — string Kind exists |
| 3 | **Protocols + records** | ~3-5 sessions | **YES** — new Value kind + dispatch tables |
| 4 | `case` / `condp` / `for` macros | ~1 session | NO — pure expansion |
| 5 | Broader `core.nx` stdlib breadth | ongoing | NO — user-land |
| 6 | Regex | ~1 session import / more if scratch | NO if importing |

Items 1, 4, 5, 6 are well-understood "do the obvious work."
Items 2, 3 have design surface — peer-AI turn 74 pins below.

---

### 10.1 Item 1 — Atoms (peer-AI turn 74 §A)

In-memory mutable cell. The simplest Clojure concurrency primitive.

**Design pins:**
  - New `Kind.atom = 34`. Heap-allocated `AtomBox { value: Value }`.
    Stored in `vm.runtime_arena`.
  - **Equality**: atoms compare by IDENTITY, NOT contained value.
    `(= (atom 1) (atom 1))` → false. Critical.
  - Native fns to install in `nexis.core`:
    - `(atom init)` → atom
    - `(atom? x)` → bool
    - `(reset! a v)` → v (unconditional set)
    - `(swap! a f & args)` → new value (read → apply f → write)
    - `(swap-vals! a f & args)` → `[old new]` 2-vector
    - `(compare-and-set! a old new)` → bool
  - `swap!` uses `VM.callValue` (same pattern as `db/alter!`).
    If `f` throws, atom is NOT mutated.
  - `@a` works via the UNIVERSAL `deref` (extend dispatch in
    `db/deref` to add the atom arm; or — better — RENAME
    `db/deref` to `deref` in `nexis.core` and keep `db/deref`
    as an alias).
  - Single-threaded VM in v1 — no actual CAS retry semantics;
    `compare-and-set!` is just an atomic check-and-set under
    the single-threaded execution model. Document.
  - Validators / watches / metadata DEFERRED.

**Sub-step:** one session, one commit. Add Kind, native fns,
universal-deref extension, integration tests, commit.

---

### 10.2 Item 2 — Strings as first-class + basic I/O (peer-AI turn 74 §B)

`Kind.string = 16` already exists in value.zig with heap
representation. The stdlib just doesn't expose much yet.

**Design pins:**

Core string API (install in `nexis.core`):
```clojure
(str & xs)         ; concat any-to-string; nil→""; matches Clojure
(string? x)        ; predicate
(subs s start)
(subs s start end)
(count s)          ; EXTEND existing count to strings
(nth s i)          ; EXTEND existing nth to strings
```

`str` semantics (Clojure-canonical):
```clojure
(str)             => ""
(str nil)         => ""
(str :x)          => ":x"
(str "a" 1 :b)    => "a1:b"
```

`nexis.string` namespace (separate, not auto-referred — like Clojure's
`clojure.string`):
```clojure
nexis.string/lower-case
nexis.string/upper-case
nexis.string/trim
nexis.string/split
nexis.string/join
nexis.string/replace
```

I/O fns (install in `nexis.core` — synchronous, UTF-8 only):
```clojure
(slurp path)        ; read file → string
(spit path content) ; write string → file
(print & xs)        ; stdout, no newline
(println & xs)      ; stdout + newline
(prn & xs)          ; reader-readable form
```

**Print distinction** (matches Clojure):
  - `str` / `print` / `println` → human-ish, strings unquoted
  - `prn` → reader-readable, strings quoted + escaped
  - v1.alpha can ship with ONE formatter shared by all four;
    document that `prn` will diverge once a separate
    pr-str-style formatter lands.

**Catchable error keywords:**
  - `:io-error`
  - `:file-not-found`
  - `:invalid-path`
  - `:utf8-error`

**File ops**: use Zig 0.16 `std.Io.Dir` (same pattern as
src/loader.zig). Loader is the working reference for the
I/O pattern; copy from there.

**Deferred**: readers/writers, `with-open`, binary I/O,
encodings beyond UTF-8, append-mode option maps.

**Sub-steps:**
  - **5.2a** — `str` + `string?` + extend `count`/`nth` + core
    string ops in `nexis.core`. One commit.
  - **5.2b** — `nexis.string` namespace with case/trim/split/
    join/replace. One commit.
  - **5.2c** — I/O fns (`slurp`/`spit`/`print`/`println`/`prn`).
    One commit. NOTE: extracting `formatValue` from cli.zig into
    a public stdlib fn is part of this; print/println share it.

---

### 10.3 Item 3 — Protocols + Records (peer-AI turn 74 §C)

**The BIG one.** Real new design ground. The Clojure pattern:

```clojure
(defprotocol IFoo
  (bar [this x])
  (baz [this x y]))

(defrecord Counter [n]
  IFoo
  (bar [this x] (assoc this :n (+ x (:n this))))
  (baz [this x y] [:counter (+ x y)]))

(extend-protocol IFoo
  Map
  (bar [m x] (assoc m :extended x))
  (baz [m x y] [:map x y]))

(satisfies? IFoo (Counter. 0))   ; => true
(bar (Counter. 5) 3)              ; => #Counter{:n 8}
(bar {} 99)                        ; => {:extended 99}
```

**Architectural pin: ONE `Kind.record = 35`, NOT tagged maps,
NOT one kind per record type.**

Tagged maps tempting but create semantic problems: record
identity blurs, equality with plain maps accidental, dispatch
inspects map contents, fields/extras get messy.

Per-record-type new kinds is IMPOSSIBLE: our 6-bit kind tag
can't support dynamic per-record kinds.

Middle ground: one `Kind.record` with a `RecordTypeId` in the
heap body.

**Storage shape:**
```zig
Kind.record = 35
RecordValue {
    type_id: RecordTypeId,         // points at RecordType metadata
    fields: Value (persistent_map), // keyword → value
}
```

**Protocol dispatch key (unified):**
```zig
DispatchType = union(enum) {
    kind: Value.Kind,         // built-ins (.string, .persistent_map, ...)
    record_type: RecordTypeId,
    default,                  // Object/Any fallback
};
```

For a receiver:
```text
if kind == .record:
    key = .record_type(record.type_id)
else:
    key = .kind(value.kind())
```

**Protocol object shape:**
```zig
Protocol {
    name: QualifiedSymbol,
    methods: HashMap(method_name → MethodSpec),
}

MethodSpec {
    name: []const u8,
    arities: []u16,
    impls: HashMap(DispatchType → *Closure),
    default_impl: ?*Closure,
}
```

**`defprotocol`** (host macro / special form):
  1. Create a Protocol object stored as a Var in the current ns.
  2. For each method, generate a DISPATCHER fn (or native fn)
     that looks up the impl via the protocol's dispatch table:
     ```text
     (defn bar [this x]
       (let [impl (lookup-protocol-impl IFoo :bar this)]
         (if impl
           (impl this x)
           (throw :no-protocol-impl))))
     ```
  - Native fn is easier for v1 (needs to walk internal tables).

**`defrecord`** (host macro / special form):
  1. Create RecordType metadata (name, fields list, ns) and
     register in the current namespace.
  2. Generate `(->Counter n)` positional constructor + `Counter?`
     predicate.
  3. Register provided protocol impls in the protocol tables.
  4. (Optional) `map->Counter` constructor.

**`extend-protocol` / `extend-type`** — mutate protocol method
tables. Dispatch targets:
  - Built-in type names: `String`, `Map`, `Vector`, `List`,
    `Nil`, `Atom`, `Set`, `Keyword`, `Symbol`, `Number`, ...
    Resolve via name → `Value.Kind` lookup table.
  - Record names → `RecordTypeId`.
  - `Object` or `Any` → `DispatchType.default`.

**`satisfies?`** — check that ALL of the protocol's methods
have an impl/default for the receiver's dispatch key.

**Field access** (minimum):
  - `(get rec :n)` — works like map get
  - `(assoc rec :n v)` — returns a record of the same type with
    updated field map
  - Extra keys: allow (record carries extmap) OR reject. Lean:
    allow, store in extmap; matches Clojure's semantics.

**Sub-steps (3-5 sessions):**
  - **5.3a** — `Kind.record` + `RecordType` + `RecordTypeId`
    registry on VM + basic constructor/predicate/get/assoc.
    NO protocols yet. One commit.
  - **5.3b** — `defprotocol` + dispatcher fns + protocol Var
    storage. One commit.
  - **5.3c** — `defrecord` with inline impls, registers in
    protocol tables. One commit.
  - **5.3d** — `extend-protocol` / `extend-type` / `satisfies?`
    + `Object`/`Any` default fallback. One commit.

**Hand-trace before code**: walk through `(defprotocol IFoo
(bar [this]))` + `(defrecord Counter [n] IFoo (bar [this] n))`
+ `(bar (Counter. 5))` end-to-end through:
  - defprotocol expansion → Var registration + dispatcher fn
  - defrecord expansion → RecordType + ->Counter ctor + impl
    registered in Protocol's method table
  - (Counter. 5) → record Value construction
  - (bar (Counter. 5)) → dispatcher native fn → lookup
    DispatchType.record_type(Counter.type_id) → invoke impl

---

### 10.4 Item 4 — `case` / `condp` / `for` macros

Pure expansion. All three are user-defmacros in `core.nx` or
host macros in expand.zig.

**`case`** (peer-AI turn 74 §4 trap): expand to chained `if`
with a gensym for single-eval of the test expression:
```clojure
(case e k1 v1 k2 v2 default)
→
(let [g# e]
  (if (= g# k1) v1
    (if (= g# k2) v2
      default)))
```
Clojure's `case` uses hash dispatch + compile-time constants;
the chained-if expansion is v1-acceptable performance.

**`condp`** — like `cond` but tests `(pred test-expr clause)`
for each clause.

**`for`** (peer-AI turn 74 §4 warning): full Clojure `for`
supports `:let` / `:when` / `:while` + lazy seq + multi-binding.
**v1 scope: subset only.** Document clearly. Lean:
  - Multi-binding cartesian product: yes
  - `:when` (filter): yes
  - `:let`: yes
  - `:while`: no
  - Lazy seq: no — EAGER list/vector return
  - Call it "nexis `for`, a subset of Clojure `for`" in docs.

**Effort**: ~1 session, one commit. Maybe split into 5.4a
(case+condp, trivial) and 5.4b (for, subset).

---

### 10.5 Item 5 — Broader `core.nx` stdlib

Pure user-land. Add to `src/stdlib/core.nx`:
```
partition / partition-by
interleave / interpose
frequencies / group-by
distinct / dedupe
zipmap / merge / merge-with
update / update-in / assoc-in / get-in
some / every? / not-any? / not-every?
comp / juxt / partial / complement
constantly / fnil
min / max / min-key / max-key
sort / sort-by (uses < — easy)
range with optional start/step (currently only single-arg)
```

ALL written in nexis. Test against expected eager-seq results.

**Effort**: ongoing, low-risk per addition. One commit per
batch of ~5-10 fns.

---

### 10.6 Item 6 — Regex (peer-AI turn 74 §6 warning)

NOT purely mechanical. Decisions:
  - Pick regex backend: import a Zig regex library (PCRE-style),
    OR write a small one (defer).
  - New `Kind.regex` opaque-Value (compiled regex object).
  - Match result shape: Clojure returns matched-substring or
    `[whole, group1, group2, ...]` vector for capture groups.
  - Native fns: `re-find`, `re-matches`, `re-seq`, `re-pattern`,
    `re-quote-replacement`, optional `re-groups`.

Keep regex SEPARATE from string basics (5.2). Don't conflate.

**Effort**: ~1 session if importing a Zig regex lib; multiple
sessions if writing from scratch.

---

### 10.7 Suggested ordering

Per leverage + risk:

1. **Atoms (Item 1)** — small, gives users in-memory mutable
   state. Most-asked-for after persistent state.
2. **Strings + I/O (Item 2)** — unlocks `(slurp ...)` /
   `(println ...)` — every real program needs these.
3. **case / condp / for subset (Item 4)** — easy macro wins.
4. **Broader core.nx (Item 5, ongoing)** — start in parallel
   with Items 1-4; each addition is low-risk.
5. **Protocols + records (Item 3)** — biggest, most architectural.
   Save for when 1+2+4 are stable so you're working against a
   solid foundation.
6. **Regex (Item 6)** — depends on library decision; do
   separately.

After Items 1+2+4: you can write a non-trivial nexis program
that LOOKS like Clojure and uses the same idioms (immutable
data + atoms + I/O + macros).

After Item 3: you can port a typical Clojure library that
uses protocols + records (which is most of them).

After Items 5+6: typical Clojure libraries that don't touch
Java interop are within porting reach.

---

### 10.8 Phase 5 EXIT criterion

Per PLAN.md §21 Phase 5 (reframed by us in this handoff):

**A non-trivial Clojure-style application — not just a script,
but a multi-file project using atoms + protocols + records +
require + multiple stdlib utilities — runs end-to-end on
nexis with no source modifications beyond namespace renames
(`clojure.string` → `nexis.string`, etc.).**

Candidate demos:
  - Port a small Datascript-style in-memory entity store.
  - Port a small JSON parser written in pure Clojure.
  - Port a stripped-down `clj-time`-style date library.
  - Write a multi-file todo CLI with protocols for storage backends
    (in-memory vs. durable via Phase 4).

---

### 10.9 Architectural surface that's settled

The hard stuff is DONE. These interfaces are stable; new work
builds on them WITHOUT reshaping:

- **Value model** (16-byte tagged Value, Kind enum). New kinds
  add to the enum (currently 30 used). Heap-kind bodies are
  free-form per-kind.
- **VM** (group-based opcode dispatch, frame management,
  callValue reentrancy, handler/finally stacks).
- **Compiler** (lowerForm → Tiny → bytecode; emitter; var_table).
- **Expander** (per-form-rule walker, syntax-quote, host +
  user macros, compile-eval callback, namespace + load
  callbacks).
- **Namespaces** (registry + auto-refer + qualified resolution
  + alias tables + loader).
- **Codec** (round-trip for all v1 kinds).
- **emdb integration** (Connection, txn handles, codec-wired
  read/write/scan).

The single Phase-2 residual still on the wish-list:
  - **Runtime VmError SrcSpans** (PC→source map per Routine).
    Currently runtime errors lack source spans. ~1 session,
    bounded. Nice UX win; not blocking anything.

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

1. Run `git log --oneline -15` and `git status`. Confirm you're
   at the most recent commit on a clean main. HEAD should be
   `8189bf8` (phase 4.0f) or later.
2. Run `zig build phase2-test --summary all`. Confirm 563
   phase2 tests + supporting categories, all green. Full
   `zig build test` includes Phase 1 randomized property
   tests (peaks ~1 GB RAM; can OOM-kill on smaller boxes —
   use `phase2-test` for inner-loop.)
3. Run the Phase 4 EXIT demo to confirm durable identity
   actually works:
   ```
   $ rm -f /tmp/todos.edb
   $ cd /tmp && /path/to/bin/nexis run /path/to/examples/todo-app.nx
   $ /path/to/bin/nexis run /path/to/examples/todo-app.nx
   ```
   Second run should show `:completed 1` (state PERSISTED).
4. Read PLAN.md §0-§3 (positioning + non-goals) and §21
   (roadmap with current ship status). Skim §15 (durable
   identity model) since Phase 4 is done. Read §23 (frozen
   decisions) before any architectural proposal.
5. Read this HANDOFF.md §10 (Phase 5 plan with peer-AI turn
   74 design pins for atoms, strings/IO, protocols).
6. Read AGENTS.md, ZIG-0.16.0-{REFERENCE,QUICKSTART}.md,
   docs/MACROEXPAND.md (for understanding how user macros
   work — protocols will be macros too).
7. Post a short status summary:
   - HEAD commit, test count, Phase 4 demo passed/failed.
   - Which Item from §10 you propose starting (default per
     §10.7 ordering: Item 1 atoms first).
   - Any clarifying questions.
8. After user confirms, engage peer AI via `user-ai` MCP with
   `conversation_id: "nexis-phase-1"` for a strategy check on
   your chosen item BEFORE writing code. (Turn count is ~74
   as of this handoff; the conversation has FULL context on
   architectural decisions from Phases 0-4.)
9. Hand-trace before code for protocols (Item 3). It's the
   only Item where doing this matters; the others are obvious
   once the design pin is locked.

Good luck. Every commit you ship is already being reviewed by
peer AI, by the user, and by the quality bar in §11. Hold the
line.

Phase 4 sealed the differentiated pitch ("Clojure + Datomic,
single binary"). Phase 5 closes the "yes you can run real
Clojure-style code" gap. The hard architectural work is DONE;
what's left is breadth and a few specific new abstractions —
all designed in §10.
```

---

A few notes about the handoff mechanics:

- **Conversation thread**: `conversation_id: "nexis-phase-1"` is now ~35 turns and ~14 sessions deep. Peer AI will remember everything we've discussed, including specific corrections it has made (turn 33's KindMismatch alignment, turn 34's three closure bugs, turn 35's 15 drifts). This is enormous accumulated context — preserving it is high-leverage.
- **Test count**: `563 phase2 + 86 reader/golden = 649 fast suite` is the ground truth for "clean starting state" at HEAD `8189bf8`.
- **Conversation thread**: `conversation_id: "nexis-phase-1"` is now ~74 turns deep. Peer AI has full context on every architectural decision from Phases 0-4, including the Phase 5 design pins for atoms/strings/protocols (turn 74). Don't make peer re-derive what it already pinned.
- **Spec convergence**: COMPILER.md and VM.md are now the load-bearing contracts for steps #3-#11. The amendment logs in each cite the peer-AI turn that drove each change.
- **Hand-trace discipline**: two hand-traces this session caught spec holes that would have manifested as bugs in step #5. Recommend the next AI do at least one before any non-trivial step (probably step #5 itself, since closures are the most novel design surface).
