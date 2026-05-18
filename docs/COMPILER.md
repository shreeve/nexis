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
   ▼  macroexpand (src/expand.zig) — recursive to fixed point
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
  - `let*` / `loop*` bindings are sequential with **strict
    left-of-self visibility** (peer-AI turn 32 hand-trace):
    binding-i's RHS sees bindings `1..i-1` but does **NOT** see
    binding-i's own LHS. Binding-i's LHS shadows from
    binding-i+1 onward and throughout the body. Concrete:
    `(let* [n n] body)` reads the outer `n` for the RHS, then
    binds the loop/let `n` for use in subsequent bindings and
    `body`. `(let* [x e1 x e2] body)` is well-formed: `e2` sees
    the first `x` binding; the first `x` is shadowed by the
    second from `body` onward (NOT a `:duplicate-binding` —
    duplicate binding only fires across positions in a single
    parameter list, where there's no sequential semantics).
  - `fn*` self-name (the optional `name?` in
    `(fn* name? [params...] body...)`) binds as a **lexical
    local** in scope across the function body, bound to the
    closure value itself (peer-AI turn 32 hand-trace). This
    makes recursive self-calls work without requiring a `def`
    to have completed and without paying for Var indirection on
    the recursive path. Resolution priority for the self-name
    inside the body follows rule #2 (lexical local) ahead of
    rules #4–#7. Equivalent to Clojure's `(fn name [...] ...)`
    semantics.
  - Duplicate bindings within a single parameter list (`fn*`
    params, `catch` binding) raise `:duplicate-binding`.
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
  - **Capture-cell slot liveness** (peer-AI turn 35): a slot
    holding an `UpvalCell*` (boxed local, or a placeholder
    cell allocated for `letfn*` / named `fn*` self-reference)
    is an ordinary live value for slot-allocation purposes.
    If the cell is needed after a function call (per the
    range-call ABI's call-clobbered region in `VM.md §6`) or
    by a later `closure:make` descriptor's `local_cell_slot`
    source, its slot MUST NOT be placed in the call-clobbered
    region at or above any `call_base`. Concrete hazard:
    `(let* [x 1, f (g), h (fn [] x)] h)` — if `x`'s cell slot
    is allocated inside the call block for `(g)`, the
    subsequent `closure:make` for `h` reads garbage.
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

(Peer-AI turn 35 holistic-review amendment: previous wording
referenced the obsolete `closure:make-closure` opcode name and
under-specified the named-fn self-reference lowering.)

- Create a new routine for this `fn*`. Compile it recursively.
  The routine is registered in the **current** routine's
  constant pool as a `function-proto` entry; its constant-pool
  index becomes operand A of the eventual `closure:make`.
- Capture analysis on the body identifies which enclosing-frame
  locals the body references. For each, build a capture
  descriptor entry: `local_cell_slot(s)` if the captured
  binding is a local of the immediate enclosing frame,
  `inherited_upvalue(u)` if it's a capture inherited from an
  outer closure currently being compiled. Register the
  descriptor in the current routine's capture-descriptor
  table; its index becomes operand B.
- Emit `closure:make A=proto_const B=cap_desc C=result_slot`
  per `VM.md §6`. The result is a closure value (VALUE.md
  kind 22).

**Named `fn*` self-name** (peer-AI turn 35; the §4.3 amendment
pinned the resolver semantics; this pins the lowering):

A named `fn*` whose body refers to itself recursively requires
a placeholder cell exactly like single-binding `letfn*`,
because at `closure:make` time the closure value does not yet
exist:

```
; for (fn* fact [n] ... (fact (- n 1)))
closure:new-cell  s_self_cell
; the routine for fact is compiled with one upvalue:
;   capture descriptor [local_cell_slot s_self_cell]
;   so inside the body, fact resolves to u:0 → cell deref
closure:make      proto(fact-body), cap_desc, s_closure
closure:init-cell s_self_cell, s_closure
; s_closure now holds the fully-formed closure;
; s_self_cell's cell now holds the closure value;
; recursive calls inside fact's body see fact via u:0
```

If the body never references the self-name, the placeholder
cell can be elided and `closure:make` emitted with an empty
capture descriptor (zero sources).

- Multi-arity `(fn* ([[a] ...] [[a b] ...]))` is **macro-
  lowered** before reaching the compiler; `fn*` takes a single
  arity list.

#### 5.6 `(recur args...)`

(Peer-AI turn 35 holistic-review amendment: previous wording
described only the non-captured case, contradicting the
captured-loop-binding rule that `VM.md §6` now pins.)

**Common skeleton** (both captured and non-captured cases):
- Lower each `arg` into a temporary slot.
- Move temporaries into the target's binding slots using
  **parallel-assignment semantics** (peer-AI turn 35: a naive
  sequential move corrupts arguments when the target slots
  alias an earlier source — e.g., `(loop* [a b, b a] (recur b
  a))`). Implementation MAY use a small temporary buffer (the
  same machinery `call:tailcall` uses for its arg slide per
  `VM.md §6`).
- Emit `jump:jmp` to the target's entry label.
- **Invariant**: no `call` opcode is emitted. Constant-stack
  guaranteed per PLAN §11.3.

**For non-captured loop bindings** (the common case):
- The slot move is the entire rebind.
- No heap allocation per iteration.

**For captured loop bindings** (peer-AI turn 35, semantically
mandatory): the analyzer MUST emit cell-fresh-per-iteration,
NOT cell mutation. The canonical hazard is:

```clojure
(loop [i 0 acc []]
  (if (< i 3)
    (recur (+ i 1) (conj acc (fn [] i)))
    acc))
;; Closures must capture 0, 1, 2 — NOT 3, 3, 3.
```

If `recur` mutated a single shared `UpvalCell` for `i`,
closures created in earlier iterations would observe the
final value. That breaks Clojure-equivalent immutable
lexical binding semantics.

Lowering for a captured loop binding's recur step:

```
; compute new value into a temp slot
math:add        s_new_value, ...
; allocate a fresh initialized cell holding the new value
mov:move        s_tmp, s_new_value
closure:box-local s_tmp                ; s_tmp := fresh cell
mov:move        s_binding_slot, s_tmp  ; install fresh cell
                                       ;   into binding slot
jump:jmp        L_loop
```

The fresh cell is heap-allocated; this iteration cost is
**semantically required** (not optional), and the
constant-heap-per-iteration guarantee from earlier wording
applies only to non-captured bindings. See `VM.md §11`
amendment for the runtime-side phrasing.

`recur` does NOT use the U-store path (`store(u:N, ...)` is
reserved for Phase 3+ dynamic-binding rebinding per `VM.md
§6`). The fresh-cell pattern above is the only correct
mechanism in v1.

#### 5.6b `(letfn* [name1 (fn* ...) name2 (fn* ...) ...] body...)`

(Peer-AI turn 35 holistic-review amendment: `letfn*` is in
PLAN §6.1's primitive-core list but was missing from
COMPILER.md's lowering rules. This section closes the gap.)

`letfn*` establishes mutually-recursive function bindings.
Unlike `let*`, all bindings on the LHS are visible to ALL
RHSs (and to the body), enabling functions to refer to each
other.

**Lowering** (mirrors `VM.md §6` `closure:new-cell` /
`closure:init-cell` discipline):

1. **Allocate placeholder cells**: for each binding `name_i`,
   emit `closure:new-cell s_name_i_cell`. After this phase,
   each name's slot holds an uninitialized `UpvalCell*`.
2. **Compile each `(fn* ...)` body**: each function's
   capture descriptor lists ALL `letfn*` names it references
   (including itself), each as a `local_cell_slot(s_name_j_cell)`
   source in the current frame.
3. **Construct each closure**: for each binding, emit
   `closure:make proto_i, cap_desc_i, s_closure_i`. At this
   point each closure exists, capturing the cells that other
   closures will fill in.
4. **Initialize the cells**: emit `closure:init-cell
   s_name_i_cell, s_closure_i` for each binding. After this
   phase, each cell holds its final closure value, and all
   the closures observe each other through their captured cells.
5. **Lower body** as `do`. Body references to `name_i`
   resolve to the cells via the same capture machinery.

**Resolution invariant** (per §4.3 + this lowering): all
`letfn*` names are visible to ALL RHSs. The classic Clojure
example `(letfn [(even? [n] (if (zero? n) true (odd? (dec n))))
(odd? [n] (if (zero? n) false (even? (dec n))))] (even? 10))`
relies on this.

**Slot allocation**: the placeholder cell slots must remain
live across the `closure:make` calls (per §4.4 capture-cell
liveness rule) AND across the `closure:init-cell` calls. The
analyzer treats them as standard live-across-call values.

**Errors**: a `letfn*` body that calls a `name` BEFORE the
corresponding `init-cell` runs would surface
`:uninitialized-cell` at runtime. The compiler's lowering
sequence above (allocate-all → make-all → init-all) rules
this out for ordinary `letfn*` use.

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

Captured-only boxing (peer-AI turn 28 Q2; descriptor-based
construction + cell access opcodes per turn 34; reads/writes
wording corrected per turn 35; **lazy boxing model** per
turn 40 — see §6.1 for the one-pass-compiler implementation
discipline that supersedes earlier "at binding time" wording).

- A local is **captured** iff any nested `fn*` body references
  it. Captured classification is computed by the analyzer for
  a real two-pass compiler, OR discovered lazily by a one-pass
  compiler — see §6.1.
- **Non-captured locals**: plain frame slots. Read / write via
  SCVU slot operands. Zero per-op overhead.
- **Captured locals**: the bound value is wrapped in an
  `UpvalCell` (VM.md §6). The local's slot holds the **cell
  pointer**, not the direct value.
  - **Reads in the defining frame** use `closure:get-cell
    A=dst_slot B=cell_slot` to dereference and copy the
    cell's contents into a value slot. Plain slot operands
    do NOT auto-deref cells (peer-AI turn 34: making them do
    so would conflate cell-pointer storage with cell-content
    storage and break descriptor-based capture).
  - **Reads inside a child closure body** use the U operand
    kind on existing opcodes — e.g., `mov:move s0, u:0`,
    `math:add s0, u:0, c:1`. `resolve(u:N)` dereferences the
    cell automatically.
  - **Writes are forbidden in v1** for ordinary captured
    locals. PLAN §6.1 scopes `set!` to dynamic-Var rebinding,
    not lexical-local mutation. The U-store path is reserved
    (`store(u:N, ...)` returns `:unsupported-write`); the
    only mechanism by which a captured loop-binding cell
    "changes" across iterations is the fresh-cell-per-
    iteration pattern documented in §5.6 — which allocates a
    NEW cell rather than mutating the existing one.
- **Closure creation** uses `closure:make A=prototype_const
  B=capture_desc C=result_slot` (VM.md §6, descriptor-based).
  Sources in the descriptor name each upvalue cell as either
  `local_cell_slot(s)` (raw cell pointer in current frame's
  slot `s`) or `inherited_upvalue(u)` (raw cell pointer from
  current closure's `upvalues[u]`).
- **Mutually-recursive closures (`letfn*`, named `fn*`
  self-reference)**: use `closure:new-cell` to allocate
  uninitialized placeholder cells, construct each closure
  capturing those cells, then `closure:init-cell` to fill in
  each placeholder with its final closure value. See §5.5
  (named `fn*` self-name) and §5.x (`letfn*`).
- **Closure invocation**: the callee's frame is prepared with
  an upvalue pointer array copied from the closure; U#
  operands resolve via the callee frame's upvalue array.

#### 6.1 Pre-analysis capture, binding-time boxing (peer-AI turn 44)

The v1 implementation in `src/compile.zig` does
**capture pre-analysis per `let*` and per `fn*`**, then emits
`closure:box-local` at **binding time** (or function entry for
captured params), making the runtime cell-vs-direct status of
each slot **provably stable across all control-flow paths**.

**History**: an earlier amendment (peer-AI turn 40) proposed
"lazy boxing" — emit `closure:box-local` at the moment an inner
closure first captures a binding, mutating the binding's
`BindingRef` from `.direct_slot` to `.cell_slot` mid-codegen.
That design was elegant for straight-line code but **fundamentally
broken under control flow**: if the inner closure is created in a
branch (e.g., `(if false (fn* [] x) 0)`), the `box-local` lives
in the unreachable branch, while subsequent same-frame reads
emit `closure:get-cell` against an unboxed slot — `:expected-cell`
trap on a perfectly valid program. Peer-AI turn 44 caught this
before the implementation was committed; this section was
rewritten to the pre-analysis model below.

**The pre-analysis algorithm** (per `let*` / `fn*`):

1. **Capture-set computation** — `freeVarsAcrossFn(body, locally_bound)`
   walks the Tiny tree under `body`, accumulating the set of
   names that are referenced by ANY enclosed `fn*` body and
   that are NOT bound locally to that `fn*`. The walk recurses
   into `fn*` bodies with that fn's params as the inner-bound
   set; the result percolates up to the enclosing scope. This
   is "free vars across function boundaries" — exactly the set
   of names the enclosing scope's bindings might have to box.

2. **`let*` binding-time decision**: when binding `name` at
   slot `s`, check whether `name ∈ freeVarsAcrossFn(remaining
   bindings + body)`. If yes, immediately emit
   `closure:box-local s` and push the binding as `.cell_slot(s)`.
   If no, push as `.direct_slot(s)`. The `closure:box-local`
   instruction sits in the routine's straight-line prelude, so
   it executes on every code path that reaches the let body.

3. **`fn*` param decision**: when entering a `fn*` body, check
   each param against `freeVarsAcrossFn(body)`. Box captured
   params at function entry (immediately after argument
   reception); push as `.cell_slot`.

4. **Same-frame read dispatch** (in `compileSymbol`):

   ```
   .direct_slot(s) → mov:move dst, slot(s)
   .cell_slot(s)   → closure:get-cell dst, slot(s)
   .upvalue(u)     → mov:move dst, u:u   (resolve(u) deref's the cell)
   ```

5. **Capture from parent scope** (in `resolveOrCapture`): when
   a child Emitter resolves a name to a parent-scope binding,
   the parent's binding is **already** `.cell_slot` if the name
   appears in any `fn*` body within the parent's scope (which
   includes the child being compiled). If the resolution
   returns `.direct_slot` instead, that's a compiler bug
   (pre-analysis missed a capture). Implementation asserts
   this via a debug-only check.

6. **`BindingRef`** is **immutable from binding time onward** in
   the pre-analysis model. There is no `ensureBoxed` mid-
   codegen mutation. The data structure is the same union as
   before:

   ```zig
   pub const BindingRef = union(enum) {
       direct_slot: u12,
       cell_slot: u12,
       upvalue: u12,
   };
   ```

**Implementation cost**: the `freeVarsAcrossFn` walker is ~80
LOC of pure Tiny-tree traversal; runs once per `let*` and once
per `fn*`. For the small Tiny surface this is trivially fast.
When real reader-form integration lands (step #8+), the
macroexpander/analyzer already walks the form tree, so the
analysis can be folded into existing passes.

**Soundness invariant** (peer-AI turn 44):
> A binding is `.cell_slot` iff `closure:box-local` was emitted
> for its slot in the routine's prelude (or function entry for
> params), which guarantees the slot holds an `UpvalCell*` on
> every reachable runtime path. `closure:get-cell` and
> `closure:make`'s `local_cell_slot` source can therefore use
> strict cell-only semantics with no runtime "ensure cell"
> dynamic check.

This invariant holds because the `closure:box-local` for a
captured binding sits in straight-line code (let-binding
prelude or fn-entry prelude) that EVERY reachable code path
traverses before any inner `fn*` could possibly construct a
closure that references the binding.

**Invariants** (continuation):
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

- `src/expand.zig`: inline tests for recursive expansion,
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
   - **Bootstrap exception note** (peer-AI turn 35): the
     tiny compiler may emit `math:add c0, c1` for `(+ 1 2)`
     even though §4.4's minimal constant-folding rule would
     fold the same source form to the literal `3`. The
     purpose of step #2 is to exercise the VM/compiler
     bytecode interface end-to-end, not to demonstrate the
     analyzer's folding (which doesn't exist until
     resolver/analyzer commits land). When the real
     analyzer arrives, `(+ 1 2)` folds at compile time and
     `math:add` is no longer emitted for it; tests that
     pinned bytecode shape against the bootstrap compiler
     are expected to be rewritten then.

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
- **2026-05-15** (§4.3 amendment): Two clarifications surfaced
  by a hand-trace of `(defn fact [n] (loop [n n acc 1] (if
  (< n 2) acc (recur (- n 1) (* n acc)))))` through the full
  pipeline before any compiler code was written.
  (1) `let*` / `loop*` binding sequentiality tightened to
  spell out left-of-self visibility — binding-i's RHS sees
  bindings `1..i-1` but NOT binding-i's own LHS. The `[n n]`
  pattern depends on this; tracing exposed that the prior
  one-line statement was ambiguous.
  (2) `fn*` self-name binding pinned as a lexical local
  carrying the closure value itself (Clojure semantics).
  Without this, `(fn* fact [n] ... (fact ...))` patterns
  would have been forced through Var indirection or required
  `def` to have completed first. Both amendments are
  no-implementation-cost; they pin behavior the implementation
  was going to need anyway.
- **2026-05-15** (§6.1 added — lazy-boxing model): Pre-step-#5
  strategy turn (peer-AI turn 40) introduced lazy boxing as a
  one-pass alternative to binding-time boxing. The §6.1 text
  described the lazy-boxing discipline. **SUPERSEDED on
  2026-05-16 by peer-AI turn 44** — see entry below.

- **2026-05-16** (§6.1 rewritten — pre-analysis): peer-AI
  turn 44 caught that the lazy-boxing model is **fundamentally
  not control-flow safe**. When an inner closure is created in
  a branch (e.g., `(if false (fn* [] x) 0)`), lazy boxing
  emits `closure:box-local` inside the branch's code, while
  mutating the binding's `BindingRef` to `.cell_slot` in
  compile-time scope. At runtime, the branch may not execute,
  so the box-local is skipped. Subsequent same-frame reads
  emit `closure:get-cell` against an unboxed slot — traps
  `:expected-cell` on a perfectly valid program. The bug was
  caught BEFORE any commit landed it (the implementation was
  in-progress with 575/575 tests passing because no test
  exercised control-flow + capture together).
  §6.1 rewritten to describe **pre-analysis**: walk the Tiny
  tree per `let*` and per `fn*` to compute the captured-name
  set BEFORE codegen, emit `closure:box-local` at binding
  time (or function entry for captured params) so the
  emission sits in straight-line code that every reachable
  path traverses. `BindingRef` becomes immutable from binding
  time onward; no `ensureBoxed` mid-codegen mutation.
  Soundness invariant: a binding is `.cell_slot` iff its
  `closure:box-local` is in straight-line prelude code that
  dominates every reachable use. Same-frame reads
  (`closure:get-cell`) and capture descriptor sources
  (`local_cell_slot`) can use strict cell-only semantics with
  no runtime "ensure cell" dynamic check.
  The implementation cost is ~80 LOC of pure Tiny-tree walking
  for the analyzer (`freeVarsAcrossFn`); trivially fast at
  v1's small Tiny surface. Future reader-form integration can
  fold the analysis into existing macroexpander/analyzer
  passes.

- **2026-05-16** (§5.5 + §5.6b implementation): Step 5c lands
  named `fn*` self-reference + `letfn*` primitive lowering.
  Both use the placeholder-cell pattern documented in §5.6b
  (peer-AI turn 34): a `closure:new-cell` allocates an
  uninitialized cell BEFORE `closure:make` runs (so the
  capture descriptor's `local_cell_slot` source can reference
  it), then `closure:init-cell` finalizes the cell with the
  constructed closure value AFTER `closure:make`. The cell-
  pointer-by-reference contract of `closure:make` makes this
  work — `make` copies the raw cell pointer, not its contents,
  so the order "alloc cell → make closure (captures pointer)
  → init cell" is well-defined.
  Named `fn*` is implemented as a degenerate single-binding
  letfn (one cell, one capture, one init); when the body
  doesn't reference its self-name (one freeVars check), no
  placeholder is allocated. `letfn*` rejects duplicate
  binding names (mutual visibility makes duplicates
  ambiguous; matches Clojure).
  Implementation cost: ~150 LOC compile.zig (compileLetFnStar
  + compileFn named arm + analyzer arms for letfn_star) +
  ~50 LOC vm.zig (new_cell / init_cell handlers). 23 new
  tests (7 VM + 16 compile). Tests cover dead-branch self-
  refs (forcing placeholder allocation without runtime use),
  forward references inside letfn*, true mutual recursion,
  three-binding chains, shadowing (named-self shadowed by
  inner let, named-self shadows outer binding, param shadows
  self-name), mixed-source capture descriptors, scope
  restoration.

  **Compiler invariant (peer-AI turn 46)**: code generated by
  the compiler MUST NOT introduce any user-code execution
  point between `closure:make` and its matching
  `closure:init-cell`. This makes the placeholder cell's
  uninitialized state structurally invisible to user code.
  Malformed hand-written bytecode that violates this still
  surfaces cleanly via `:uninitialized-cell`.

- **2026-05-16** (§5.6 + §5.7 implementation, peer-AI turns
  47 + 48): Step 5d lands tail-position machinery for `recur`
  and `loop*`, plus the `cmp:lt` opcode + `Tiny.lt`.
  Implementation pieces:
  - `Tiny.loop_star`, `Tiny.recur` variants.
  - `RecurTarget { entry_pc, binding_slots, captured_mask,
    kind }` threaded through `compileExpr` (added 4th
    parameter). Propagation rules (peer-AI turn 47): if
    then/else inherit, do-last inherit, let* body inherit,
    letfn* body inherit; loop* body REPLACES (new loop
    target); fn* body REPLACES (new fn target, never
    propagates outer); all other positions (if test, do
    non-last, let* RHS, callee, call args, recur args, lt
    operands, add operands) pass null.
  - `compileLoopStar` mirrors `compileLetStar` for binding
    setup + captured-binding pre-analysis, then marks
    `entry_pc = currentPc()` AFTER the box-local prelude.
  - `compileRecur` validates target presence (else
    `RecurOutsideTail`) and arity match (else
    `RecurArityMismatch`), evaluates args into fresh temp
    slots (parallel-assignment safety for aliasing patterns
    like `(recur b a)`), then installs into target slots:
    for captured bindings emits
    `closure:box-local temp` + `mov:move target, temp`
    (fresh cell per iteration, per VM.md §11 + §5.6
    captured-recur invariant); for non-captured emits
    plain `mov:move`. Final `jump:jmp entry_pc`. No call
    opcode emitted.
  - `compileFn` sets up a fn `RecurTarget` after the
    captured-param boxing prelude so `(recur ...)` inside
    a fn body without an enclosing `loop*` rebinds the
    params + jumps back to the function entry (constant-
    stack self-recursion). `param_slots[i] = i`,
    `captured_mask[i] = captured_in_body.contains(p)`.
  - Analyzer arms added for `loop_star` (let*-style
    sequential visibility) and `recur` (recurse into args
    so nested fn captures are detected).
  - VM `stack_high_water` + `frame_high_water` counters
    instrumented on grow ops only (peer-AI turn 47 §Q5 —
    final-length check is insufficient).
  - `cmp:lt` opcode + `Tiny.lt` (5d0): comparisons live in
    their own group, NOT in `math` (peer-AI turn 47:
    keeping arithmetic ISA clean). Needed to write any
    terminating loop test.
  Tests: 607 → 636 (+29). Coverage includes 10k-iteration
  constant-stack assertion (high-water unchanged), aliasing
  recur swap, **canonical captured-loop-binding fresh-cell
  test** (`(loop* [i 0 f (fn* [] 999)] (if (< i 1) (recur
  (+ i 1) (fn* [] i)) (f))) => 0` proves fresh cells per
  iteration), captured fn-param fresh-cell test, `letfn*`
  body inheriting loop target, recur inside letfn fn body
  targeting that fn, nested-fn-RESETS-target, nested-loop-
  only-targets-inner-loop, dead-branch recur, and all the
  non-tail error cases (top-level, let RHS, do non-last,
  if test, call arg, arity mismatches).

  **`call:tailcall` deliberately deferred** (peer-AI turn 47):
  its context propagation differs from recur's — emitting
  `call:tailcall` in a position that is loop-body-tail but
  not function-tail would generate wrong code. Will land
  with its own context infrastructure in a later step.

- **2026-05-16** (§5.5 + §6 implementation, peer-AI turns
  49 + 50): Step 5e lands variadic params via the explicit
  `rest_param` shape — `(fn* [a b & r] body)` lowers with
  `Tiny.fn_star.rest_param = "r"`, NOT by encoding `&` as a
  fake symbol in `params`. The reader-form integration in
  step #7 will parse `[a b & r]` source syntax into the
  same Tiny shape.
  - `compileFn` validates rest doesn't shadow any fixed
    param, includes rest in the captured-binding pre-
    analysis env, binds rest at slot `params.len`, and emits
    `closure:box-local` on the rest slot in the prelude if
    captured (same machinery as ordinary params).
  - `Compiled` and `vm.Routine` carry `fixed_arity: u16 +
    variadic: bool` (renamed from `arity: u16` — minimal
    churn, clearer than a union for v1).
  - Variadic `recur` is deliberately **REJECTED** with new
    `CompileError.UnsupportedFeature` (peer-AI turn 49 §G7
    "decide explicitly, implement explicitly or reject
    explicitly"). `RecurTarget.variadic` propagates the
    flag; `compileRecur` checks it before arity. Proper
    variadic recur (rebuild rest list per iteration) lands
    in a later sub-step.
  - 10 compile tests: rest unused/used/empty/zero-fixed/
    no-args/duplicate-name-error/captured-rest-with-content-
    verification/variadic-too-few-args-runtime-trap/
    variadic-recur-rejected/non-variadic-recur-still-works.

  **Captured rest param** works identically to captured
  ordinary params via the existing pre-analysis machinery:
  the inner closure captures the rest slot's `*UpvalCell`,
  and dereferences yield the rest list value. Verified by
  `(((fn* [a & r] (fn* [] r)) 1 2 3))` returning the list
  `(2 3)` with full content verification.

- **2026-05-17** (§4.1 + §5 — step #7 frontend, peer-AI
  turns 51 + 53 + 54): Step #7 adds the Form→Tiny lowering
  frontend. The compiler's input surface is now BOTH
  `*const Tiny` (existing backend tests, 135+ regression
  cases) AND `*const reader.Form` / source bytes. Per
  peer-AI turn 51's architecture, Tiny remains the IR;
  there is NO parallel Form→bytecode codegen path —
  `lowerForm` translates Form to Tiny, then the proven
  backend (capture pre-analysis, RecurTarget threading,
  variadic rest, Var fall-through, defn placeholder cells,
  etc.) takes over unchanged.

  Public entries:
  - `lowerForm(allocator, form)` → `*Tiny`
  - `compileForm(allocator, form)` / `compileFormWithNamespace(...)`
  - `compileSource(allocator, source)` / `compileSourceWithNamespace(...)`
    — end-to-end: parser.parseForm + Reader.readOneForm +
    lowerForm + compileTinyWithNamespace.

  Sub-decomposition (4 commits):
  - **#7a** (4df693d): scaffolding + literals (nil/bool/int)
    + symbols. First time real `.nx` source compiles
    end-to-end.
  - **#7b** (3b4d467): list dispatch + special forms
    (do/if/quote-of-scalar) + intrinsics (+/<) with the
    LowerEnv lexical-shadowing guard. New error variants:
    MalformedForm, ExpectedSymbol, ExpectedVector,
    ReaderFailure.
  - **#7c** (2c24a69): binding/fn forms (let*/fn*/letfn*/
    loop*/recur) via Form. Implicit-do for multi-form
    bodies. `&` rest detection in parseParams. Optional
    self-name detection in lowerFnStar.
  - **#7d** (c5d3f52): vars (def/defn/var) via Form.
    Canonical defn forward-reference end-to-end via
    source: `(do (defn f [] (g)) (defn g [] 42) (f))` → 42.

  **LowerEnv** (compile.zig): linked-list of name sets,
  parent-walked on lookup. Tracks lexical names ONLY for
  intrinsic shadowing — NOT slot resolution (that's the
  backend's resolveOrCapture). Special forms are RESERVED
  (recognized regardless of lexical bindings); inlineable
  intrinsics (+/<) check `env.contains(name)` and fall
  through to ordinary call if shadowed. Documented
  staged limitations:
  - **Namespace-level Var shadowing NOT handled**:
    `(do (def + f) (+ 1 2))` still inlines `+` to
    `Tiny.add` (test pins this as explicit staged behavior
    per peer-AI turn 54 §"Nice-to-fix #1"). Lexical-only
    is the must-have; Var-aware inlining is Phase 3+.
  - **Qualified symbols** (`foo/x`) NOT supported anywhere
    (multi-ns is post-v1 surface).

  **Unsupported Form datums** (raise `UnsupportedFeature`):
  - real, char, string, keyword (deferred to a later
    commit when Phase 1 numerics/strings integrate with
    the const pool)
  - vector, map, set as expressions (collection literals
    require compile-time call into coll/{champ,vector},
    deferred)
  - quoted symbol/keyword/string/compound-collection
    (requires Tiny.literal + Interner integration; step
    #8 macroexpander will force this)
  - syntax_quote, unquote, unquote_splicing (step #8
    macroexpander territory)
  - deref (atoms aren't a Phase 2 feature)
  - anon_fn (`#(...)` shorthand; step #8 macroexpander)
  - with_meta (`^{...}` metadata; Phase 3+)
  - letfn* with rest param (Tiny.FnBinding has no
    rest_param field yet; staged per peer-AI turn 54 §D)

  Tests: 686 → 757 (+71 across #7a/b/c/d + the turn-54
  nice-to-fix tests). All shadowing scenarios from peer-AI
  turn 53 §"Critical trap" covered end-to-end via source
  syntax. `zig build phase2-test` runs all phase2 tests
  in ~2s. The bootstrap Tiny tests (135) remain as a
  regression bed; eventual retirement is Phase 6 polish.

  Next: step #8 (macroexpander). Requires Tiny.literal +
  symbol/keyword Value support; the deferral list above
  will start closing as #8 lands.

- **2026-05-17** (step E1 prereq + step H1 CLI runner +
  step #8 spec pinned):

  **E1** (97aa9dd, peer-AI turn 55 §K): `Tiny.literal: Value`
  added as a generic Value constant variant. Used by quoted
  unqualified symbols/keywords, which lower via a shared
  Interner threaded into the compile path. New entries:
  - `compileFormFull(allocator, form, ns?, interner?)`
  - `compileSourceFull(allocator, source, ns?, interner?)`
  Existing entries (`compileSource`, `compileSourceWithNamespace`,
  `compileForm`, `compileFormWithNamespace`) preserved as
  null-interner wrappers — every prior test runs unchanged.

  **LowerCtx** struct (NEW) bundles `{env, interner}` and is
  threaded through every lower\* helper as one parameter.
  Replaces the prior env-only parameter. `withEnv(child)`
  creates a child context inheriting the interner. 15 function
  signatures rotated via mechanical bulk-rename; semantics
  unchanged.

  Bare `:keyword` now self-evaluates via `Tiny.literal` (per
  Clojure semantics; keywords are always self-evaluating).
  Without an interner, falls back to `UnsupportedFeature`.

  Quoted nil/bool/int still use existing Tiny variants
  (peer-AI turn 53 §Q1 — saves const-pool entries).
  Quoted compound collections still `UnsupportedFeature`;
  step #8c will close that via `(#%list ...)` / `(#%concat
  ...)` emission.

  **H1** (98a7d33, peer-AI turn 55 §H): `bin/nexis` CLI
  runner. `src/cli.zig` (~200 LOC) reads file, parses ALL
  top-level forms via `parser.parseProgram` +
  `Reader.readProgram`, compiles each via `compileFormFull`
  (sharing VM's ns + interner), runs each, prints final
  result via a tiny inline formatValue. First user-visible
  `.nx` programs run end-to-end: `examples/hello.nx`,
  `sum10.nx`, `forward-ref.nx`. New `zig build nexis` step.

  **MACROEXPAND.md** spec pinned per peer-AI turn 56 (11
  edits to draft applied BEFORE coding):
  - MacroFn takes `*ExpandContext` (carries gensym
    counter, interner, host_macros table).
  - Gensym counter lives on context, NOT VM.
  - Reordered #8b ↔ #8c: host macros first (FormBuilder
    only, no runtime list/concat). Syntax-quote +
    list/concat separate.
  - Per-form traversal rules table (each special form has
    its own walking rule).
  - `quote` AND `syntax_quote` both opaque in #8a.
  - SrcSpan rule pinned: synthetic forms get the macro
    call's origin.
  - Error model split: `MacroDepthExceeded` distinct from
    `MacroExpansionFailure`.
  - Removed multi-arity `defn` from step-#8 macro table
    (defer to Phase 3 with `defmacro`).
  - Added `let`/`fn`/`loop` rename macros per
    CLOJURE-REVIEW.md §1.1.
  - `or` MUST use gensym (avoid double-evaluation); exact
    expansion shape spec'd.
  - Syntax-quote-emitted `list`/`concat` use internal
    `#%list` / `#%concat` special forms — unshadowable.

  Tests: 757 → 767 (+10 across E1 + H1 keyword tests).
  `zig build phase2-test` stays ~2s.
