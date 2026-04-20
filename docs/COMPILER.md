## COMPILER.md — Phase 2 compiler: pipeline, lowering, contracts

**Status**: Phase 2 spec. Authoritative contract for the nexis
compiler (reader → bytecode routines). Derivative from `PLAN.md`
§6 (compiler-known primitives), §11 (pipeline), §12 (ISA), and
`docs/FORMS.md` (Form schema, already shipped in Phase 0).
Companion doc: `docs/VM.md` (runtime execution of the bytecode
this compiler emits).

**Discipline**: this spec pins **invariants and contracts**, not
concrete Zig struct layouts. The internal shape of `Resolved`,
`IR`, and compiler-side data structures is an implementation
choice that should emerge from code contact. What each stage
guarantees about its input and output is frozen here. (Peer-AI
turn 28.)

> **Freeze level** (peer-AI turn 30): the compiler/VM interface
> is frozen at the level of **semantic obligations** — operand
> meanings, frame/routine logical contents, the calling and
> `recur` contracts, the error taxonomy. It is NOT frozen at
> the level of concrete Zig struct layout. If implementation
> discovers a better shape for any internal representation, the
> spec does not need to change — provided the semantic
> obligations still hold end-to-end.

---

### 1. Scope

**In (Phase 2):**
- Reader → `Form` tree (already shipped; `src/reader.zig`).
- Macroexpander: recursive expansion to fixed point before
  resolve/analyze/codegen.
- Resolver: classifies every symbol reference (local / upvalue /
  Var / special-form / error-unresolved).
- Analyzer: marks tail positions, identifies captured locals,
  lifts literals, performs minimal constant folding.
- Codegen: emits 64-bit bytecode per `docs/VM.md`, per-routine
  constant pools, per-routine var tables, source-span maps.
- Linker: registers compiled routines on namespace Vars, caches
  `.nx.o` optionally.
- Primitive core: `quote`, `if`, `do`, `let*`, `fn*`, `recur`,
  `loop*`, `def`, `var`, `try`/`catch`/`finally`, `throw`.
- Error reporting: stable `SrcSpan`-backed error taxonomy; macro
  origin + expansion-site dual reporting.
- Testing: golden-style source → checked-in disassembly + full-
  pipeline `(eval-string ...)` tests.

**Out (Phase 3+):**
- User-facing macros (`let`, `fn`, `loop`, `defn`, `when`, `cond`,
  threading macros, destructuring) — Phase 3 stdlib.
- stdlib kernel (`+`, `-`, `=`, `map`, `reduce`, etc.) — Phase 3.
- Protocols, records, schema — Phase 4+.
- Profile-guided optimization, inline caches, operand-specialized
  opcodes — Phase 6.
- Incremental recompilation, bytecode caching beyond the single-
  file `.nx.o` — Phase 5 tooling.
- Ahead-of-time linker / whole-program optimization — Phase 7+.

---

### 2. Pipeline recap

Cross-ref `PLAN.md` §11.1:

```
source.nx or REPL line
   │
   ▼  parser (nexus-generated, Phase 0)
Sexp tree
   │
   ▼  reader (src/reader.zig, Phase 0)
Form tree
   │
   ▼  macroexpand (src/macroexpand.zig) — recursive to fixed point
Expanded Form tree
   │
   ▼  resolve (src/resolve.zig)
Resolved AST
   │
   ▼  analyze (src/analyze.zig)
IR (SSA-lite, slot-assigned, tail-position-marked)
   │
   ▼  codegen (src/compile.zig)
Bytecode module (per-routine code + pools + sourcemap)
   │
   ▼  link (src/loader.zig)
Loaded, callable routines
```

Phase boundaries are **strict**. Every stage has a documented
invariant on what it accepts and what it produces (§4). A stage
that receives ill-formed input from the previous stage is a
compiler bug, not a user error.

---

### 3. Compile-time arena model

**Invariant (peer-AI turn 28 Q4)**: macro expansion intermediates,
resolver structures, analyzer IR, and codegen scratch all live in
a **per-top-level-form arena**. The arena is freed en masse when
the top-level form's bytecode is linked into its namespace.

- **Lifetime**: one arena per top-level form at the REPL /
  per-form in a file during file compilation. File compilation
  does NOT retain a whole-file arena; individual `defn`s free
  their arena as they complete.
- **Runtime-heap cross-over**: the compile-time arena NEVER
  holds pointers into the runtime heap and the runtime heap
  NEVER holds pointers into the compile-time arena. The two
  address spaces are isolated.
- **Quoted literal lifting**: when a `quote` form's contents
  must reach runtime as a `Value`, the compiler **deep-copies**
  the quoted structure from the compile-time arena into the
  runtime heap during codegen. The resulting runtime `Value` is
  placed in the routine's constant pool.
- **No GC**: the compile-time arena is a plain bump allocator.
  It is not tracked by `src/gc.zig`. Freeing is the arena drop.
- **Implementation allocator**: the arena is a thin wrapper
  over `std.heap.ArenaAllocator` or an equivalent bump
  allocator. Not load-bearing on the spec.

**Rationale**: macro expansion creates huge amounts of
short-lived Form garbage. Running GC over it would dwarf the
actual compilation work. Arena freeing is O(1).

---

### 4. Stage invariants

Each stage accepts and produces data matching these contracts.
Internal representations (exact Zig struct shapes) are
implementation choices, NOT part of the spec.

#### 4.1 Reader — already shipped

- **Input**: Sexp tree from the nexus-generated parser.
- **Output**: `Form` tree per `docs/FORMS.md`.
- **Guarantees**:
  - Every Form has a valid `SrcSpan` (§8).
  - User metadata normalized (`^:kw` → `{:kw true}`, etc.).
  - Reader-level statically-detectable errors rejected
    (duplicate map keys, odd map arity, nested `#(...)`, bare
    unquote outside `syntax-quote`).
  - `syntax-quote`, `unquote`, `unquote-splice` preserved as
    unexpanded structural markers — NOT resolved at reader time.

#### 4.2 Macroexpander

- **Input**: Form tree from reader.
- **Output**: Form tree with no remaining top-level macro
  symbols; special forms preserved; user metadata preserved.

- **Guarantees**:
  - **Recursive to fixed point** (peer-AI turn 28 Q3): expansion
    runs until a traversal finds no remaining macro references.
    NOT a single pass.
  - Outermost-first expansion. When a macro call expands, the
    resulting Form is itself re-expanded recursively before
    siblings are processed.
  - `&form` and `&env` bindings injected into each macro
    expansion per Clojure convention.
  - Recursion depth bounded by a configurable limit (default
    1024). Exceeding it raises `:macroexpansion-too-deep` with
    the macro-call chain as context.
  - `syntax-quote` expansion handled as an early sub-pass within
    the macroexpander: auto-qualification, auto-gensym,
    `~` / `~@` handling. The output is ordinary Forms — no
    `syntax-quote`, `unquote`, `unquote-splice` markers remain
    after this pass.
  - `(#%anon-fn body)` (from `#(...)` reader sugar) is lowered
    to `(fn* [%1 %2 ...] body)` here, with positional arg
    symbols resolved by scanning the body.
  - SrcSpan threaded from macro-call site to expansion result;
    expansion provenance attached to the Form's annotation
    field (§2.6 of `docs/FORMS.md`).

- **Errors**: `:macro-resolution-failed` (macro name unbound),
  `:macroexpansion-too-deep`, `:macro-signature-error` (if a
  macro call's arity is statically detectable as wrong).

#### 4.3 Resolver

- **Input**: Expanded Form tree.
- **Output**: "Resolved AST" — every symbol reference classified.

- **Symbol classification (priority order)**:
  1. **Special form** — if the symbol is a primitive-core name
     (`quote`, `if`, `do`, `let*`, `fn*`, `recur`, `loop*`,
     `def`, `var`, `try`, `catch`, `finally`, `throw`) AND in
     an operator position.
  2. **Lexical local** — innermost binding from `let*`, `fn*`,
     `loop*`, `catch`.
  3. **Captured upvalue** — a lexical local from an enclosing
     `fn*` whose body is currently being compiled. The
     analyzer (§4.4) converts these to upvalue slots; the
     resolver just marks them as lexically bound to an outer
     scope.
  4. **Namespace-qualified symbol** (`my.ns/foo`): resolved to a
     Var in `my.ns`. Error `:ns-not-found` if `my.ns` is
     unloaded, `:unresolved-symbol` if `foo` is not interned
     there.
  5. **Aliased-qualified symbol** (`ns-alias/foo`): the alias
     is resolved via the current namespace's alias table.
  6. **Current-namespace mapping**: bare symbol looked up in the
     current namespace's refer table.
  7. **Core-namespace mapping**: bare symbol looked up in
     `nexis.core` (the implicit refer target).
  8. **Error**: `:unresolved-symbol` with SrcSpan.

- **Additional guarantees**:
  - Shadow rules: inner bindings shadow outer; symbols bound in
    a destructuring pattern shadow enclosing scope within the
    binding's body but not the binding expression itself.
  - `let*` / `loop*` bindings are sequential — each subsequent
    binding sees the earlier ones.
  - Duplicate bindings within a single `let*` / `loop*` /
    parameter list raise `:duplicate-binding`.
  - `recur` in resolver is a special-form marker; tail-position
    validation happens in analyzer.

- **Errors**: `:unresolved-symbol`, `:ns-not-found`,
  `:duplicate-binding`, `:invalid-special-form-context` (e.g.,
  `quote` with zero or multiple operands).

#### 4.4 Analyzer

- **Input**: Resolved AST.
- **Output**: IR — a lowered form suitable for codegen. Exact
  structure left flexible; the following invariants are pinned.

- **Guarantees**:
  - Every local binding is tagged **captured** or **not
    captured**. A local is captured iff at least one closure
    within its body references it.
  - Non-captured locals remain plain frame slots at runtime.
  - Captured locals are represented as **heap cells** (see
    `docs/VM.md` §6); the analyzer emits an instruction to
    allocate the cell at binding time, and closures capture
    references to cells (not value copies).
  - Every call site in a tail position (per PLAN §11.3) is
    marked. Tail positions are: the final expression of a
    `fn*` body, the final expression of an arm of `if` / `do` /
    `let*` / `loop*` / `try` (when not protected by pending
    `finally`).
  - `recur` occurrences are validated: must be in tail position
    of the nearest enclosing `fn*` / `loop*`. Arity must match.
    Violations raise `:recur-outside-tail` /
    `:recur-arity-mismatch`.
  - Frame-slot assignment: each local and each compiler-
    generated temporary gets a slot number. Slots are reused
    across disjoint lifetimes (classic register allocator
    pattern; liveness-based).
  - Literal lifting: every literal that does not fit as an
    inline immediate (small fixnum, nil, true, false) is lifted
    into the routine's constant pool. Fully-static collection
    literals are materialized at compile time into runtime
    heap values and placed in the constant pool; collection
    literals with non-literal sub-expressions are compiled as
    construction code at runtime.

- **Minimal constant folding** (peer-AI turn 28, bounded scope):
  - Literal fixnum / float arithmetic: `(+ 1 2)` folds to `3`.
  - Literal comparisons: `(< 1 2)` folds to `true`.
  - `(if <literal-truthy> a b)` → `a`; `(if <literal-falsy> a b)`
    → `b`.
  - `(quote x)` self-evaluates as the quoted literal.
  - **No** aggressive folding of user-facing predicates, no
    algebraic rewriting, no reordering. Keeps the analyzer
    simple and the test surface small.

- **Errors**: `:recur-outside-tail`, `:recur-arity-mismatch`,
  `:slot-exhaustion` (hard limit reached),
  `:closure-depth-exceeded` (nested `fn*` beyond a configured
  depth).

#### 4.5 Codegen

- **Input**: IR from analyzer.
- **Output**: Bytecode routine per `docs/VM.md` — code bytes +
  constant pool + var table + upvalue descriptor + source-span
  map.

- **Invariants**:
  - One routine per `fn*` in the source (plus the implicit
    top-level routine for any top-level form).
  - Instructions are 64 bits (+ 20-bit extensions where
    operands exceed 12 bits per `VM.md`).
  - Constant pool entries are deduplicated within a routine;
    cross-routine sharing via the shared C# pool (nil, true,
    false, small-int cache, empty collections, common keywords)
    is always preferred when available.
  - Var references compile to `V#` operands resolving at load
    time via the linker (§4.7).
  - Upvalue slots in a closure are numbered 0..N; the closure
    captures a `[N]*UpvalCell` array at construction time.
  - Source-span map: every emitted instruction has a back-
    reference to the originating Form's SrcSpan (§8), indexed
    by the routine's instruction offset.

- **Lowering rules for the primitive core**: §5.

- **Errors**: `:bytecode-overflow` (routine too large),
  `:const-pool-overflow`, `:extension-encoding-failure`.

#### 4.6 Source-span map

- Populated during codegen; written into the routine's metadata.
- Indexed by instruction offset; yields the original Form's
  SrcSpan.
- Enables:
  - Precise error reporting at runtime.
  - `(disassemble foo)` showing source lines alongside bytecode.
  - Phase 5 tooling: single-step debugger, coverage, profiling.

#### 4.7 Linker

- **Input**: Compiled routine(s) + the current namespace.
- **Output**: Each routine registered on its Var root.

- **Responsibilities**:
  - Attach routine to its Var (new Var or replace existing
    root).
  - Resolve `V#` operands in the routine's code by binding to
    the target Var handle.
  - Optionally cache to `.nx.o` (format pinned in em; magic
    number differs per PLAN §12.6).
  - Mark all routines as callable atomically — either the full
    top-level form installs or none of it does.

- **Errors**: `:ns-var-conflict` (Var already defined as
  `:private` in another namespace), `:ns-write-protected`
  (namespace is in a locked state — Phase 3+).

---

### 5. Primitive core lowering

Exact bytecode semantics are in `docs/VM.md`; this section pins
what source forms lower to, in terms of opcode groups.

All examples assume emitted-code abstraction — actual opcode
variants (hot-path kind, etc.) are codegen details.

#### 5.1 `(quote x)`

- Literal lifting: `x` is deep-copied into the runtime heap
  (if it's a collection) or emitted as an immediate Value (if
  scalar). The reference lands in the constant pool.
- Runtime: `mov:load-const` into the result slot.

#### 5.2 `(if test then else?)`

- Lower `test` into a slot.
- `jump:if-false` to `else-label` if the result slot is
  `false-or-nil`.
- Emit `then` code, leaving result in the result slot.
- `jump:jmp` to `end-label`.
- `else-label`: emit `else` code (or `mov:load-nil` if
  `else` is absent).
- `end-label`: continuation.

Constant-folded `if` (per §4.4) skips the unreachable arm
entirely — no dead code emitted.

#### 5.3 `(do expr...)`

- Lower each `expr` for its effect only; discard the result
  slot.
- The final `expr` lowers into the result slot of the `do`.

#### 5.4 `(let* [b1 v1 b2 v2 ...] body...)`

- Allocate a slot for each binding (or a heap cell if captured).
- Lower each `v` expression into the binding's slot/cell in
  sequence (left-to-right).
- Lower `body` as `do`.

#### 5.5 `(fn* name? [params...] body...)`

- Create a new routine for this `fn*`. Compile it recursively.
- Emit `closure:make-closure` with a reference to the compiled
  routine and the enclosing frame's captured-cell addresses for
  each upvalue.
- The result is a closure value (VALUE.md kind 22) carrying
  the routine + upvalue cells.

- Multi-arity `(fn* ([[a] ...] [[a b] ...]))` is **macro-
  lowered** before reaching the compiler; `fn*` takes a single
  arity list.

#### 5.6 `(recur args...)`

- Lower each `arg` into a temporary slot.
- Emit `mov:move` instructions to copy the temporaries into the
  target's binding slots.
- Emit `jump:jmp` to the target's entry label.
- **Invariant**: no `call` opcode is emitted. Constant-space
  guaranteed per PLAN §11.3.

#### 5.7 `(loop* [b1 v1 b2 v2 ...] body...)`

- Same as `let*` for binding setup.
- Emit an entry label after binding setup.
- Lower `body` as `do`; `recur` within `body` targets the entry
  label with the binding slots as the target.

#### 5.8 `(def name expr?)`

- Resolve `name` to a Var in the current namespace (creating
  one if absent).
- Lower `expr` (or `nil` if absent) into a result slot.
- Emit `var:store-var` V#(name), result-slot.

#### 5.9 `(var name)`

- Emit `var:load-var V#(name)` into a result slot.
- Returns the Var object itself (not its root value); used by
  macros and tooling.

#### 5.10 `(try body... (catch type binding catch-body...)?
    (finally finally-body...)?)`

**Minimal v1 semantics** (peer-AI turn 28):

- `try` installs a handler region via `ctrl:try-enter`.
- `body` executes normally.
- On a caught exception, control transfers to the matching
  `catch`'s entry; the thrown value is bound to `binding`.
- `finally` runs on both normal and exceptional paths.
- Exact exception-object mechanics (stack traces, error chains,
  cause fields) are **not** fully specified here; spec will
  grow in the implementation commit based on code contact.

#### 5.11 `(throw expr)`

- Lower `expr` into a slot.
- Emit `ctrl:throw` result-slot. Control transfers to nearest
  matching `catch` (or exits the VM with an unhandled-error
  report if none).

---

### 6. Closure and upvalue contract

Captured-only boxing (peer-AI turn 28 Q2):

- A local is **captured** iff any nested `fn*` body references
  it. Captured classification is computed by the analyzer.
- **Non-captured locals**: plain frame slots. Read / write via
  SCVU slot operands. Zero per-op overhead.
- **Captured locals**: at the binding point, the compiler emits
  an allocation for an `UpvalCell` heap object (VM.md §6) and
  initializes the cell with the bound value. The local's slot
  in the frame holds the cell pointer, not the direct value.
  Reads / writes dereference the cell.
- **Closure creation**: `closure:make-closure` takes a routine
  reference + an array of `UpvalCell` pointers sourced from
  the enclosing frame's captured-binding slots.
- **Closure invocation**: the callee's frame is prepared with an
  upvalue pointer array copied from the closure; U# operands
  resolve via the callee frame's upvalue array.

**Invariants**:
- `UpvalCell` is a **heap object**, traced by the GC like any
  other heap value.
- Closures carry references to cells, NOT copies of cell
  contents. Rebinding the cell (via `set!` or similar —
  future-work) is visible to all closures sharing it.
- A closure's captured-cell array is immutable after creation;
  only the cells' contents may change.

---

### 7. Error reporting

**Every error** raised by the compiler carries:

- A stable **error kind** keyword (e.g., `:unresolved-symbol`,
  `:arity-mismatch`, `:recur-outside-tail`). These keywords
  form a stable taxonomy tools can match on; additions are
  non-breaking, renames are breaking.
- A **primary SrcSpan** — where the error was detected.
- An optional **secondary SrcSpan** — for errors inside macro-
  expanded code, the macro's own source location.
- An expansion-provenance chain when applicable — a list of
  macro-call-sites leading up to the error site.
- A human-readable message.
- Contextual data (e.g., for `:arity-mismatch`, the expected
  and actual arities).

Errors are **structured values**, not just strings, so REPL and
editor tooling can render them richly.

The full taxonomy is documented inline with each stage (§4).

---

### 8. SrcSpan threading

- Every Form has a `SrcSpan` attached by the reader (Phase 0).
- Macroexpander copies the call-site SrcSpan onto expanded
  Forms; original macro source SrcSpan is attached to the
  Form's annotation field.
- Resolver/Analyzer carry SrcSpans forward unchanged.
- Codegen maps every emitted instruction to the originating
  Form's SrcSpan via the routine's source-span map.
- Runtime errors (from the VM) resolve their location by
  looking up the current PC in the map.

---

### 9. Testing plan

Phase 2 has three test layers:

#### 9.1 Unit tests per stage

- `src/macroexpand.zig`: inline tests for recursive expansion,
  fixed-point termination, syntax-quote handling, #%anon-fn
  lowering, error cases.
- `src/resolve.zig`: inline tests for every classification
  branch (local / upvalue / qualified / aliased / mapped /
  unresolved).
- `src/analyze.zig`: capture-analysis correctness, tail-position
  marking, slot-allocation invariants.
- `src/compile.zig`: per-primitive-form codegen verified against
  expected bytecode shape.

#### 9.2 Golden-style pipeline tests

- Input: a `.nx` file at `test/compiler-golden/<name>.nx`.
- Output: disassembled bytecode checked in at
  `test/compiler-golden/<name>.dis`.
- `zig build compiler-golden` runs every `.nx` through the
  full pipeline, compares disassembly, reports diff.
- Regenerate with `-Dupdate=true` (same UX as the Phase 0
  reader golden tests).

#### 9.3 Eval-string integration tests

- `test/eval/` holds `.nx` files + expected printed output.
- Each file is read, compiled, and executed; printed output
  compared against the checked-in expected file.
- Coverage: primitive core semantics, closure capture, `recur`
  TCO, `try`/`catch`, `def`/`var`.

#### 9.4 Phase 2 gate tests

Phase 2 is complete when ALL of the following hold on the
current canonical bench hardware:

1. Every primitive-core form compiles + executes correctly for
   its documented semantics (verified via §9.3 integration
   tests).
2. Recursion via `recur` in a 10k-iteration loop runs in
   constant stack space (not just constant heap — verified via
   a watermark test).
3. Closure capture works across arbitrarily deep nesting
   (property-test up to depth 10).
4. `syntax-quote` / `unquote` / `unquote-splice` produce
   structurally-equal Forms to hand-coded equivalents (property
   test).
5. Compiler errors report stable error-kind keyword + primary
   SrcSpan + macro origin when applicable.
6. All golden tests pass; full test suite remains 441/441+.
7. A bench suite addition (`bench/compiler.zig`) measures:
   compilation throughput (forms/second), eval throughput
   (simple-loop ops/second), closure-creation cost, `recur`
   per-iteration cost. Numbers recorded in `docs/PERF.md` §3.

---

### 10. Implementation sequence

Per peer-AI turn 28 Q5 — **VM-first, not compiler-last**.

Commit sequence (rough, not binding):

1. **VM kernel commit**. `src/vm.zig` with instruction
   encoding, routine layout, frame model, dispatch loop, and
   opcodes: `mov:load-const`, `mov:move`, `call:return`,
   `mov:load-nil`, `mov:load-true`, `mov:load-false`. Hand-
   assembled bytecode tests validate the dispatch loop.

2. **Tiny compiler commit** (immediately after #1). Just
   enough to lower `(+ 1 2)` with a single hard-wired `+`
   primitive. This flushes out VM interface issues before the
   VM grows further.

3. **Conditionals**. Add `jump:*` opcodes + `if` lowering.

4. **Locals + let***. Slot allocation, `let*` lowering.

5. **Functions + closures**. Add `closure:*` + `fn*` +
   non-tail `call`. Captured-binding boxing.

6. **`recur` + `loop***. Add tail `jump:jmp` lowering + tail-
   position validation.

7. **Vars + def**. Add `var:*` opcodes + `def` lowering +
   linker.

8. **Macroexpand**. Add `syntax-quote` / `unquote` /
   `unquote-splice` handling. Add `#%anon-fn` lowering.

9. **Try/catch/throw**. Minimal v1 semantics.

10. **Error reporting hardening**. Stable taxonomy across all
    stages; SrcSpan threading tested end-to-end.

11. **Golden + eval tests**. Full Phase 2 gate coverage.

Each commit lands with its own inline tests + property tests
where appropriate; Phase 2 gates (§9.4) are met across the
whole sequence, not within any single commit.

---

### 11. What's intentionally left flexible

Per peer-AI turn 28 — avoid overspecification that should emerge
from code contact:

- Exact Zig struct layouts for `Resolved`, `IR`, routine
  internal metadata. Spec the invariants they carry; let the
  implementation choose representations.
- Frame stack backing storage (contiguous / slab / segmented).
  `docs/VM.md` specs the logical frame model only.
- Exact dispatch-loop Zig snippet. `docs/VM.md` specs the
  tail-call threaded contract; code details are not frozen.
- Constant-folding beyond the minimal cases in §4.4.
  Implementation may add safe rewrites; nothing user-observable
  downstream relies on any particular fold.
- Try/catch/throw exception-object mechanics. Minimal v1
  semantics in §5.10; richer design lands when the implementation
  reaches it.

---

### 12. Cross-references

- `docs/VM.md` — bytecode format + runtime execution (companion).
- `PLAN.md` §6 — primitive core vs macro-lowered forms.
- `PLAN.md` §11 — pipeline (higher-level than this doc).
- `PLAN.md` §12 — bytecode ISA (higher-level than `VM.md`).
- `docs/FORMS.md` — Form schema (Phase 0 input).
- `docs/SEMANTICS.md` — equality, hash, numeric edges
  (runtime-side; compiler must respect).
- `docs/VALUE.md` — heap kinds; `function` is kind 22.
- `../em/docs/architecture/PIPELINE.md` — em compiler pipeline
  (template; nexis adapts for macros + closures + persistent
  collections).

---

### 13. Amendment log

- **2026-04-19** (spec commit): Initial draft. All contracts
  `proposed`. No implementation yet. Peer-AI turn 28 decisions
  embedded.
