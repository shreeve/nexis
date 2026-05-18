# nexis Phase 2 — Handoff Prompt (write this to the next AI as your first message)

```
You are taking over work on the nexis project — a modern, Zig-native Lisp
inspired by Clojure, built for persistent data, durable identity, and
world-class performance. Multi-phase implementation driven by PLAN.md at
the repository root.

Phase 1 is COMPLETE (PLAN.md §20.2). **Phase 2 is COMPLETE**:
every primitive-core form compiles + executes, macros +
syntax-quote + collections, try/catch/throw/finally, source-
span errors, property tests, bench harness, golden eval-pipeline
tests. All 7 gate items from COMPILER.md §9.4 satisfied + step
#11 integration coverage added as belt-and-suspenders.

464 phase2 tests + 86 reader/golden = 550 tests in the fast
inner-loop suite (~3s). Full suite (`zig build test`) green
including Phase 1 randomized property tests.

Phase 3 starts when the user decides: standard library bootstrap
(`stdlib/core.nx` per CLOJURE-REVIEW.md §1.1), user-defined
`defmacro` (#8d, needs compile-time VM eval), REPL, multi-
namespace via refer/alias/require, runtime VM-error catchability.

- The VM has 7 wired opcode groups: mov, cmp, math, call,
  closure, jump, var.
- The compiler handles every primitive-core form: literals,
  arithmetic (`+`), comparison (`<`), conditionals (`if`), locals
  (`let*`), do, fn* with named self-reference and `& rest`
  variadic, recursive closures with full control-flow-safe
  capture pre-analysis (5b/5c), `letfn*` with placeholder cells,
  tail-position `recur` + `loop*` (constant-stack verified to
  10k iterations), Vars + Namespace, `def` / `defn` / `(var x)`
  with forward references.
- **Real `.nx` source compiles end-to-end** via `compileSource()`
  (step #7). The reader produces Forms, `lowerForm` translates
  Form → Tiny IR, and the proven backend takes over.
- **`bin/nexis` exists** (step H1). `nexis run FILE.nx` reads a
  file, compiles + runs each top-level form, prints the final
  result. Three working examples ship: `examples/hello.nx`,
  `sum10.nx`, `forward-ref.nx`.
- **Macroexpander scaffold landed** (step #8a). `MacroexpandContext`
  + `HostMacroTable` + per-special-form traversal walker + depth
  limit + lexical-shadowing-aware macro dispatch. With an empty
  table (current default), the expander is a pure pass-through.
  Spec pinned in `docs/MACROEXPAND.md` (peer-AI turn 56 review).

SHIPPED to close Phase 2:
- **#8b** (4af8c22, 5270739): 10 host core macros (when/cond/and/or/->/->>
  + let/fn/loop renames). Default macro table wired into CLI.
- **#8c.1** (4ad8dd3): coll:list/concat opcodes + Tiny IR +
  #%list/#%concat + quoted compound lists.
- **#8c.2** (32a8d34): syntax-quote / unquote / splicing /
  auto-gensym. Caught + fixed a gating bug.
- **#8c.3** (de3c775): coll:vector + #%vector + vector quote/
  syntax-quote — unlocks the user-defmacro pattern.
- **#9.1** (2527944): try/catch/throw + cross-frame unwind.
- **#10.0** (1e5b575): SrcSpans in compile errors (gate item 5).
- **A** (b948ab0): gate items 3+4+7 — closure depth-10 property
  test + syntax-quote structural-equality property test +
  bench/main.zig compiler category (compile_simple, eval_loop,
  closure_create, eval_arith).
- **#9.2** (a610cb4): finally clauses + throw-through-finally.
  Coroutine continuation model. All 4 exit paths tested.
- **#11** (8def91d): test/integration/eval_pipeline.zig — 46
  end-to-end test cases covering every primitive-core form,
  every macro, every try/catch/finally path.

Remaining (Phase 3+):
- **#8d**: user-defined `defmacro` — requires compile-time VM
  eval. Significant scope.
- **recur inside try**: explicitly rejected in v1 (wrap try
  around loop). Tractable but not v1 priority.
- **Runtime VmError SrcSpans**: PC→source map per Routine.
  Nice-to-have UX improvement, NOT gate-blocking.
- **Maps/sets as runtime values**: requires stdlib bootstrap.
- **#(...) anon-fn reader macro**: Phase 3.
- **REPL + module loading**: Phase 3.
- **Type matchers beyond `catch any`**: post-Phase-3 type system.

Read this entire prompt before touching anything.

═══════════════════════════════════════════════════════════════════════
## 1. REPOSITORY

- Location: /Users/shreeve/Data/Code/nexis/
- Remote:   git@github.com:shreeve/nexis.git
- Branch:   main
- HEAD:     check `git log -1 --oneline`. Recent commit chain
            (newest first):
              8def91d phase 2 step #11: golden + eval pipeline integration tests
              a610cb4 phase 2 step #9.2: finally clauses + throw-through-finally
              b948ab0 phase 2 gate item A (3, 4, 7): property tests + bench
              1e5b575 phase 2 step #10.0: SrcSpan in compile errors — gate item 5 satisfied
              2527944 phase 2 step #9.1: try / catch / throw + cross-frame unwind
              de3c775 phase 2 step #8c.3: vector support — completes the macro author's toolkit
              32a8d34 phase 2 step #8c.2: syntax-quote / unquote / splicing / auto-gensym
              4ad8dd3 phase 2 step #8c.1: coll:list/concat opcodes + #%list/#%concat IR + quoted compound lists
              5270739 phase 2 step #8b: peer-AI turn 57 review fixes
              4af8c22 phase 2 step #8b: host core macros — 10 macros, all green
              0e50c77 phase 2 step #8 preflight: MACROEXPAND.md pinned
              98a7d33 phase 2 step H1: minimal CLI runner — first .nx programs execute
              97aa9dd phase 2 step E1: Tiny.literal + Interner integration
              a85b281 docs: HANDOFF.md — full refresh after step #7 + POLS cleanup
              3dbfad6 docs: README — showcase real .nx source examples
              6f1123b phase 2 step #7: peer-AI turn 54 review fixes + docs
              c5d3f52 phase 2 step #7d: vars (def/defn/var) via Form
              2c24a69 phase 2 step #7c: binding/fn forms via Form
              3b4d467 phase 2 step #7b: list dispatch + special forms + intrinsics
              4df693d phase 2 step #7a: Form→Tiny scaffolding + literals + symbols
              52eb8de docs: README — soften "zero learning curve" claim
              9e4ca42 refactor: rename hamt.zig→champ.zig + rrb.zig→vector.zig
              7387c0c docs: README.md overhaul — Phase 2 status + Clojure-on-Zig pitch
              cfcf353 docs: add docs/README.md module ↔ spec map
              58382cb chore: repo POLS cleanup (peer-AI turn 52)
              4373b6e phase 2 step #6c: defn + forward references
              ade5e7b phase 2 step #6b: def + var:store-var + symbol fall-through
              32b5436 phase 2 step #6a: Var + Namespace + var:load-var
              090c469 phase 2 step #5e: variadic params (& rest)
              cd5c47f build: add `zig build phase2-test` fast iteration target
              0eff28d phase 2 step #5d: loop* + recur + tail-position + cmp:lt
              2a44bb1 phase 2 step #5c: placeholder cells + letfn* + named fn*
              36962fe phase 2 step #5b: capture machinery (pre-analysis)
              3926fed phase 2 step #5a1: empty-capture closures + call:call/return
              8b06c3c phase 2 step #5a0.5: typed Const pool
              0330b6a phase 2 step #5a0: backing-stack frame refactor
              ...
              (full Phase 2 history: `git log --oneline | head -40`)
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

11. **ZIG-0.16.0.md — MANDATORY
    before writing any Zig.** 30+ stdlib APIs changed between 0.15
    and 0.16 in ways that silently break training-data code. See
    §6 below for the gotchas that have actually bitten us.

═══════════════════════════════════════════════════════════════════════
## 3. BUILD VERIFICATION (run on arrival)

**Two build steps; use the right one for the right loop.**

For **inner-loop Phase 2 iteration** (~3 seconds):
```
cd /Users/shreeve/Data/Code/nexis
zig build phase2-test
```
Runs ONLY vm + compile tests. Expected: **308 tests pass**
(86 vm + 222 compile as of HEAD `3dbfad6`).

For **pre-commit validation** (~3 minutes):
```
cd /Users/shreeve/Data/Code/nexis
zig build test --summary all
```
Runs the full Phase 0/1/2 suite. Expected: ~770 tests across all
modules. The ~3 min runtime is dominated by Phase 1's randomized
HAMT correctness gate (one test alone runs ~100k randomized ops in
~3 minutes, ~1 GB peak — has been OOM-killed on memory-constrained
systems; in that case rely on phase2-test for inner-loop and run
the full suite when system memory is freer). Phase 2 work doesn't
touch any of that.

If either is red, STOP and diagnose before editing.

Test breakdown at HEAD `3dbfad6`:
  Phase 2 modules (run via `zig build phase2-test`):
    86 vm        (Var/Namespace + var:* opcodes + cmp:lt + recur
                  + variadic rest + capture machinery + closures
                  + tail-position machinery + ...)
   222 compile   ((1) Tiny IR — nil/bool/int/symbol/add/lt/if/
                  let_star/do/fn_star/call/letfn_star/loop_star/
                  recur/def/var_ref/defn — 135 tests; (2) Form→
                  Tiny lowering frontend — literals, symbols,
                  list dispatch, special forms, intrinsics with
                  LowerEnv shadowing, binding/fn forms,
                  vars — 87 tests via compileSource() against
                  real source strings)
  Phase 0/1 modules (run via `zig build test`):
    Inline runtime tests (32 binaries, mostly unchanged since
    Phase 1 close): hash, value, eq, intern, heap, string, list,
    vector, bignum, champ (was hamt), transient, dispatch, gc,
    codec, db, pool, reader.
    Property tests (test/prop/, 12 files): primitive, intern,
    heap, string, list, bignum, vector, champ, gc, transient,
    codec, db.
    Golden reader tests: 10  test/golden/

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

### 7.2 Phase 2 progress (in progress, ~80% complete)

```
SHIPPED (steps #1-#7 of COMPILER.md §10's 11-step plan):
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

PENDING per COMPILER.md §10:
  [ ] step #8   NEXT — Macroexpand + syntax-quote + #%anon-fn +
                quoted-symbol/collection support + auto-gensym
                hygiene (PLAN §14.2). Closes the deferred items
                pinned at step #7:
                  - quoted symbols/keywords/strings/collections
                  - anon_fn `#(...)` shorthand
                  - syntax_quote / unquote / unquote_splicing
                  - Tiny.literal: Value variant (peer-AI turn 51
                    §Q3, deferred to #8)
                Requires symbol/keyword Value support via the
                existing Interner (src/intern.zig).
  [ ] step #9   try/catch/throw (VM.md §12 minimal v1 spec).
  [ ] step #10  Error-reporting hardening — SrcSpan threading
                end-to-end (Form.origin is already preserved by
                the reader; compile errors currently drop it).
                Bucketed CompileError.ReaderFailure expands into
                structured errors carrying the original reader
                ErrorKind + span.
  [ ] step #11  Golden + eval pipeline tests; Phase 2 gate close.

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
  [ ] src/macroexpand.zig  new module; recursive-to-fixed-point
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

### 7.5 Phase 2 gate (per COMPILER.md §9.4)

```
1. Every primitive-core form compiles + executes correctly      MOSTLY
   Via REAL .nx source through compileSource():
     nil, bool, int, symbol, +, <, if, do, quote-of-scalar,
     let*, fn* (with self-name + & rest), call, letfn*,
     loop*, recur, def, defn, (var x) — ALL WORKING.
   Pending for full gate: macros (step #8 — closes quoted
   symbols / collection literals / #(...) / syntax-quote) +
   try/catch/throw (step #9).
2. recur in 10k-iter loop runs in constant stack space          SHIPPED
   (5d test verifies both stack_high_water and frame_high_water
   are unchanged across 10k iterations)
3. Closure capture works across deeply-nested fns               SHIPPED
   (5b: 3-level transitive captures; 5c: letfn* mutual recursion
   via placeholder cells; 5e: captured rest params)
4. syntax-quote / unquote / unquote-splicing produce equivalent PENDING
   structurally-equal Forms to hand-coded equivalents
   (step #8: macroexpander)
5. Compiler errors report stable error-kind keyword + primary   PARTIAL
   SrcSpan + macro origin when applicable
   (CompileError variants exist + cover Form-side malformed
   shapes via MalformedForm/ExpectedSymbol/ExpectedVector;
   SrcSpan threading lands with step #10 — the reader already
   produces Form.origin, the compiler just doesn't propagate
   it into errors yet)
6. All golden tests pass; full test suite remains green         ON TRACK
   (~770 tests total at HEAD 3dbfad6: 86 vm + 222 compile +
    ~454 Phase 1 + 10 golden, all green)
7. bench/compiler.zig measures compilation throughput, eval     PENDING
   throughput, closure-creation cost, recur per-iter cost
   (Phase 6 polish; not a blocker for Phase 2 gate close)
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
## 10. IMMEDIATE NEXT TASK — Phase 3 onboarding

**Phase 2 is COMPLETE.** Every COMPILER.md §9.4 gate item is
satisfied + step #11 integration coverage added. The next
substantive work is Phase 3.

### Status of COMPILER.md §9.4 gate items

| # | Item | Status |
|---|---|---|
| 1 | Every primitive-core form compiles + executes | ✅ Done |
| 2 | 10k-iter `recur` constant-stack | ✅ Done |
| 3 | Closure capture depth-10 (property test) | ✅ Done (b948ab0) |
| 4 | syntax-quote/unquote/splice structural-equal (property test) | ✅ Done (b948ab0) |
| 5 | Compile errors → kind + SrcSpan + macro origin | ✅ Done (1e5b575) |
| 6 | Full suite passes (≥441 tests) | ✅ Done (550+ tests) |
| 7 | `bench/compiler.zig` (compile + eval throughput) | ✅ Done (b948ab0) |

Phase 2 step list (COMPILER.md §10) — all green:
  ✅ #1-#7: primitive core (literals → vars)
  ✅ #8a: macroexpand scaffold
  ✅ #8b: host core macros
  ✅ #8c.1/.2/.3: syntax-quote + collections
  ✅ #9.1: try/catch/throw + cross-frame unwind
  ✅ #9.2: finally + throw-through-finally
  ✅ #10.0: SrcSpan in compile errors
  ✅ #11: golden + eval-pipeline integration tests

Phase 2 PRODUCT bar:
  ✅ `bin/nexis run file.nx` — every example in examples/ runs
  ✅ ~2-3M compiles/sec, ~49 ns/recur-iteration
  ✅ Friendly error messages with file:line:col + caret
  ✅ Full Lisp macro author's toolkit (syntax-quote with
     splicing + auto-gensym + vector synthesis)

### What Phase 3 looks like

Per PLAN.md §21:
  1. **Standard library bootstrap** (`stdlib/core.nx`,
     CLOJURE-REVIEW.md §1.1 two-stage process):
     - Stage 1: trivial host-defined `defmacro` enabling
       user-written macros
     - Stage 2: redefine user-facing forms with
       destructuring, multi-arity defn, etc., from
       `core.nx`
  2. **REPL** — interactive eval loop
  3. **Module loading**: `(require ...)` / `(use ...)` /
     namespace support
  4. **Runtime VmError catchability**: convert recoverable
     VM errors to user-throwable Values
  5. **Reader macros `#(...)`**
  6. **Maps/sets as runtime values + literals**

Each of those is bounded; user picks priority.

### Recommended Phase 3 onboarding sequence

1. Read PLAN.md §21 (Phase 3 roadmap).
2. Read CLOJURE-REVIEW.md §1.1 (two-stage stdlib bootstrap).
3. Pick: `defmacro` first (the biggest leverage —
   immediately unblocks stage-1 macros), or REPL first
   (immediate UX win for any user).

### Active design surface for next-AI

The Phase 2 architecture is settled. Tiny IR + LowerCtx +
MacroexpandContext + VM's group-based opcode dispatch are
all stable interfaces. Phase 3 work BUILDS on this without
reshaping.

The one Phase-2 residual to flag: **runtime VmError
SrcSpans**. Currently runtime errors (UncaughtThrow / etc.)
lack source spans. Adding them requires a PC→source map per
Routine. Bounded work (~1 session) but pulls in a compiler-
side instruction-to-source mapping table that doesn't exist
yet. Nice-to-have for UX but post-gate.

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
4. Read at minimum: AGENTS.md, ZIG-0.16.0.md, docs/VM.md,
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
