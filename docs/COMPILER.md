## COMPILER.md — compiler: pipeline, lowering, contracts

Authoritative contract for the nexis compiler (`src/compile.zig`:
reader `Form` → `Tiny` IR → bytecode routines). Derivative from
`PLAN.md` §6 (compiler-known primitives), §11 (pipeline), §12 (ISA)
and `docs/FORMS.md` (Form schema). Companion docs: `docs/VM.md`
(runtime execution of the bytecode this compiler emits) and
`docs/MACROEXPAND.md` (the Form → Form rewriter that runs first).

**Discipline**: this spec pins **invariants and contracts**, not
concrete Zig struct layouts. The internal shape of `Tiny`, the
`Emitter` and the lowering context are implementation choices.
What each stage guarantees about its input and output is frozen
here.

> **Freeze level**: the compiler/VM interface is frozen at the
> level of **semantic obligations** — operand meanings,
> frame/routine logical contents, the calling and `recur`
> contracts, the error taxonomy. It is NOT frozen at the level of
> concrete Zig struct layout. If a better shape for any internal
> representation appears, the spec does not need to change —
> provided the semantic obligations still hold end-to-end.

---

### 1. Scope

**In:**
- Reader → `Form` tree (`src/reader.zig`, `docs/FORMS.md`).
- Macroexpander: recursive expansion to fixed point before
  lowering (`src/expand.zig`, `docs/MACROEXPAND.md`).
- Lowering: `Form` → `Tiny` IR (`lowerForm`). Every symbol
  reference is classified here (lexical local / captured upvalue
  / Var / special form / intrinsic / unresolved).
- Codegen: `Tiny` → 64-bit bytecode per `docs/VM.md`, with
  per-routine constant pools, var tables and capture-descriptor
  tables (`Emitter`).
- Linking: Var references resolve at compile time through the
  current namespace and the namespace registry; `(require ...)`
  file loading lives in `src/loader.zig`.
- Primitive core: `quote`, `if`, `do`, `let*`, `fn*`, `letfn*`,
  `recur`, `loop*`, `def`, `var`, `try`/`catch`/`finally`,
  `throw`, plus the internal constructors `#%list`, `#%concat`,
  `#%vector`, `#%map`, `#%set` that syntax-quote and quoted
  compound literals lower to.
- Error reporting: a Zig `CompileError` set plus a `SrcSpan`
  out-parameter (`LowerDiag`) for the form the error is about.
- Testing: property tests (`test/prop/compile.zig`) and an
  end-to-end eval pipeline (`test/integration/eval_pipeline.zig`).

**Absent (stated as facts):**
- No folding of computations: `(+ 1 2)` compiles to `math:add`.
  Only collections of constants are built at compile time
  (§4.4).
- No bytecode cache and no object file: nothing writes or reads
  `.nx.o`. Every run compiles from source.
- No separate resolver or analyzer module; classification and
  capture marking happen inside `lowerForm`.
- No register allocation beyond a stack of slots: a slot is
  freed when the form that allocated it is compiled (§4.4).
- No profile-guided optimization, inline caches or
  operand-specialized opcodes; no ahead-of-time linker.

---

### 2. Pipeline recap

Cross-ref `PLAN.md` §11.1:

```
source.nx or REPL line
   │
   ▼  parser (src/parser.zig, generated from nexis.grammar)
Sexp tree
   │
   ▼  reader (src/reader.zig)
Form tree
   │
   ▼  macroexpand (src/expand.zig) — recursive to fixed point
Expanded Form tree
   │
   ▼  lowerForm (src/compile.zig)
Tiny IR (symbols classified, special forms recognized, captured
         bindings marked)
   │
   ▼  Emitter (src/compile.zig) — codegen
Bytecode routines (code + consts + var_table + capture_descs)
   │
   ▼  VM (src/vm.zig)
```

Stage boundaries are **strict**. Every stage has a documented
invariant on what it accepts and what it produces (§4). A stage
that receives ill-formed input from the previous stage is a
compiler bug, not a user error.

---

### 3. Compile-time arena model

**Invariant**: Form trees, Tiny IR and the `Compiled` routine
records live in a compile arena owned by the caller of the
compile entry points.

- **Lifetime, file run** (`nexis run FILE.nx`): one compile arena
  for the whole file, released together at the end.
- **Lifetime, REPL**: every line compiles into the runtime's
  persistent arena, because closures and their routines reference
  sub-routine pointers that must outlive the line, and a line's
  definitions are called from later lines. The source bytes go
  there too (`Tiny.symbol` slices borrow from them).
- **Lifetime, `eval`**: the Form and Tiny trees and the Emitter's
  working storage live in a scratch arena freed when `eval`
  returns; the routine, its constants, span table and closure
  prototypes are compiled onto the runtime's persistent arena
  (`CompileOptions.routine_allocator`), since a closure the form
  returns, a Var it defines and the frame an escaping throw
  leaves in place outlive the call. What each `eval` keeps is its
  routine: a few hundred bytes, not the trees it came from.
- **Runtime-heap cross-over**: literal Values that must reach
  runtime (strings, bignums, collections of constants, interned
  symbols and keywords) are built through the heap and interner
  plumbed into the lowering context (`LowerCtx.heap`,
  `LowerCtx.interner`) and placed in the routine's constant pool,
  which the collector marks for as long as a frame or a closure
  can run the routine (VM.md §9). Nothing collects between
  lowering a form and running it. Without an interner, quoted
  symbols and keywords are `UnsupportedFeature`.
- **No GC**: the compile arena is a plain bump allocator, not
  tracked by `src/gc.zig`. Freeing is the arena drop.

**Rationale**: macro expansion creates large amounts of short-lived
Form garbage. Arena freeing is O(1).

---

### 4. Stage invariants

Each stage accepts and produces data matching these contracts.
Internal representations (exact Zig struct shapes) are
implementation choices, NOT part of the spec.

#### 4.1 Reader

- **Input**: Sexp tree from the generated parser.
- **Output**: `Form` tree per `docs/FORMS.md`.
- **Guarantees**:
  - Every Form has a valid `SrcSpan` (`origin`).
  - User metadata normalized (`^:kw` → `{:kw true}`, etc.).
  - Reader-level statically-detectable errors rejected
    (duplicate map keys, odd map arity, nested `#(...)`, bare
    unquote outside `syntax-quote`).
  - `syntax-quote`, `unquote`, `unquote-splice` preserved as
    unexpanded structural markers — NOT resolved at reader time.

#### 4.2 Macroexpander

Full contract in `docs/MACROEXPAND.md`. Summary of what the
compiler relies on:

- **Input**: Form tree from reader.
- **Output**: Form tree with no remaining macro calls; special
  forms preserved; `syntax_quote` / `unquote` /
  `unquote_splicing` / `anon_fn` datums rewritten away.
- **Guarantees**:
  - Recursive to fixed point: a macro's output is itself
    re-expanded before siblings are processed.
  - Expansion depth is bounded at 256 nested expansions;
    exceeding it is `CompileError.MacroDepthExceeded`.
  - Synthetic forms carry the macro call site's `origin`;
    reused subforms keep their own.
- **Errors**: `MacroDepthExceeded`, `MacroExpansionFailure`.

#### 4.3 Lowering (`lowerForm`)

- **Input**: Expanded Form tree.
- **Output**: `Tiny` tree — every symbol reference classified.

- **Symbol classification (priority order)**:
  1. **Special form** — if the symbol is a primitive-core name
     (`quote`, `if`, `do`, `let*`, `fn*`, `letfn*`, `recur`,
     `loop*`, `def`, `var`, `try`, `throw`, and the
     `#%` constructors) AND in operator position. Special forms
     are reserved: they are recognized regardless of lexical
     bindings.
  2. **Inlined core fn** — a call of `+`, `-`, `*`, `/`,
     `quot`, `mod`, `<`, `<=`, `>`, `>=` or `==` with two
     operands, of `-` or `abs` with one, or of `inc` / `dec`
     (`+` / `-` with a constant 1) lowers to one `math` or `cmp`
     instruction (`Tiny.prim`), which runs the numeric-tower
     helper the fn itself runs (VM.md §10), so results and errors
     are the fn's. It does so when the operator means
     `nexis.core`'s Var: it is not lexically bound
     (`LowerEnv`), the namespace resolves it to `nexis.core`'s Var
     rather than one it defines or refers to, and (outside
     `nexis.core`) the file or REPL line being compiled does not
     define it (`DeclaredNames`), so `(do (def + f) (+ 1 2))` calls
     `f`, as Clojure does. Otherwise the call goes through the Var
     like any other, as does any other arity. A qualified
     `nexis.core/+` and the like inline unconditionally: a
     qualified head is never a local, and host macros emit them
     (`MACROEXPAND.md` §5).
  3. **Lexical local** — innermost binding from `let*`, `fn*`,
     `loop*`, `letfn*`, `catch`, or a `fn*` self-name.
  4. **Captured upvalue** — a lexical local of an enclosing
     `fn*`. The `Emitter` converts these to upvalue slots (§6).
  5. **Namespace-qualified symbol** (`my.ns/foo`,
     `Tiny.qualified_symbol`): resolved exactly through the
     namespace registry — `prefix` must be a registered
     namespace and `foo` one of its own Vars (no parent walk,
     no lexical lookup). Aliases from `(require '[ns :as a])`
     resolve the prefix first.
  6. **Current-namespace Var**: bare symbol looked up in the
     current namespace, then up its parent chain (`user`'s
     parent is `nexis.core`, so core names resolve unqualified).
  7. **Declared-later name**: a name the same file or REPL line
     defines anywhere (`def`, `defn`, `defonce`, `defmacro`,
     `defrecord`'s names, `defprotocol` and its methods;
     `DeclaredNames`, collected before any form compiles) — so a
     form may refer to a Var a later form defines.
  8. **Error**: `UnresolvedSymbol` with the symbol's span.

- **Additional guarantees**:
  - Inner bindings shadow outer.
  - `let*` / `loop*` bindings are sequential with **strict
    left-of-self visibility**: binding-i's RHS sees bindings
    `1..i-1` but does **NOT** see binding-i's own LHS. Binding-i's
    LHS shadows from binding-i+1 onward and throughout the body.
    `(let* [n n] body)` reads the outer `n` for the RHS, then
    binds the new `n` for subsequent bindings and `body`.
    `(let* [x e1 x e2] body)` is well-formed: `e2` sees the first
    `x`; the second shadows it from `body` onward (NOT a
    `DuplicateBinding` — that error only fires across positions
    in a single parameter list, where there is no sequential
    semantics).
  - `fn*` self-name (the optional `name?` in
    `(fn* name? [params...] body...)`) binds as a **lexical
    local** in scope across the function body, bound to the
    closure value itself. Recursive self-calls work without a
    completed `def` and without Var indirection. Resolution for
    the self-name follows rule #3 ahead of rules #5–#7.
    Equivalent to Clojure's `(fn name [...] ...)`.
  - Duplicate names within a single parameter list raise
    `DuplicateParam`; a rest parameter that shadows a fixed
    parameter is the same error. Duplicate `letfn*` binding names
    raise `DuplicateBinding` (mutual visibility makes duplicates
    ambiguous; matches Clojure).
  - `(fn* [a b & r] body)` lowers with `rest_param = "r"`; `&`
    is never a parameter name. A `letfn*` binding takes a rest
    parameter the same way.
  - Every binding a closure captures is marked in its Tiny node
    as the symbol reaching it is lowered (§6.1).
  - `recur` is a marker at lowering; tail-position validation
    happens in the `Emitter` against the active `RecurTarget`.
  - `catch` takes the matcher `any` only; any other matcher is
    `UnsupportedFeature` (the expander lowers every surface
    matcher onto `any`, MACROEXPAND.md §10).

- **Errors**: `UnresolvedSymbol`, `DuplicateParam`,
  `DuplicateBinding`, `MalformedForm`, `ExpectedSymbol`,
  `ExpectedVector`, `UnsupportedFeature`,
  `StackOverflow`. An integer literal outside the i48 fixnum
  range is a bignum constant; `IntegerOutOfFixnumRange` is only
  for a hand-built `Tiny.int` outside it.

#### 4.4 Emitter — slots, captures, codegen

- **Input**: `Tiny` tree.
- **Output**: bytecode routine per `docs/VM.md` — code + typed
  constant pool + var table + capture-descriptor table +
  `slot_count` / `fixed_arity` / `variadic` / `upvalue_count`.

- **Guarantees**:
  - Every local binding arrives tagged **captured** or **not
    captured** by lowering (§6.1). A local is captured iff at
    least one `fn*` within its scope references it.
  - Non-captured locals are plain frame slots at runtime.
  - Captured locals are **heap cells** (`docs/VM.md` §6): the
    `Emitter` boxes the slot at binding time (`closure:box-local`)
    and closures capture cell pointers, not value copies.
  - `recur` occurrences are validated: must be in tail position
    of the nearest enclosing `fn*` / `loop*` (`RecurTarget`), with
    matching arity. Violations raise `RecurOutsideTail` /
    `RecurArityMismatch`. Tail positions propagate through
    `if` arms, the last form of `do`, `let*` bodies and `letfn*`
    bodies; `loop*` and `fn*` bodies install a new target; every
    other position (`if` test, non-last `do` forms, `let*` RHS,
    callee, call arguments, `recur` arguments, intrinsic
    operands) has none.
  - `recur` into a variadic `fn*` takes the fixed params plus one
    argument for the rest binding.
  - Frame-slot assignment: slots are a stack. Each local and each
    compiler-generated temporary takes the next free slot, and
    every slot a form allocated is free again once the form is
    compiled: a binding's slot lives to the end of its scope, a
    temporary until the instruction that consumes it, a call
    block until the call. A routine's `slot_count` is the most
    slots live at once, and more than 4096 live at once is
    `SlotOverflow`.
  - **Capture-cell slot liveness**: a slot holding an
    `UpvalCell*` (boxed local, or a placeholder cell for
    `letfn*` / named `fn*` self-reference) is an ordinary live
    value. If the cell is needed after a call (per the range-call
    ABI's call-clobbered region in `VM.md §6`) or by a later
    `closure:make` descriptor's `local_cell_slot` source, its
    slot is never placed at or above any `call_base`. The slot
    stack gives this for free: a call block is allocated on top
    of every slot live when its form is compiled. Concrete
    hazard: `(let* [x 1, f (g), h (fn [] x)] h)` — if `x`'s cell
    slot were allocated inside the call block for `(g)`, the
    subsequent `closure:make` for `h` would read garbage.
  - Operands in place: a `math` or `cmp` instruction,
    `jump:if-false`, `var:store-var` and `ctrl:throw` read a
    literal (as a constant), a local held directly in its slot,
    an upvalue or a Var where it is, instead of copying it into a
    slot first. Evaluation stays left to right: the left operand
    of a two-operand instruction reads a Var in place only when
    the right one is a literal or a symbol, which run no code.
  - Literal lifting: nil, booleans and fixnums have dedicated
    `mov:*` loads or inline `Tiny` variants; every other literal
    (strings, bignums, symbols, keywords) is a `Const.value` in
    the routine's constant pool.
  - A list, vector, map or set whose items are all constants —
    quoted data, `[1 2 3]`, `{:a 1}`, and the `#%` constructors
    syntax-quote emits over constants — is built once, at
    lowering, the way the VM would build it, and is one constant
    (PLAN §11.4): its size costs no slots and no instructions,
    and evaluating it twice yields the same object, as in
    Clojure. A collection with a computed item compiles to
    `coll:list` / `coll:concat` / `coll:vector` / `coll:map` /
    `coll:set` over a slot block.

- **Errors**: `RecurOutsideTail`, `RecurArityMismatch`,
  `SlotOverflow` (more than 4096 slots live at once, upvalues or
  Var-table entries in a routine), `ConstantPoolOverflow` (more
  than 4096 constants or capture descriptors), `JumpTargetOutOfRange` (a jump whose target lies
  past pc 4095: jump operands are 12-bit and there is no
  extension-instruction encoding; code past pc 4095 that nothing
  jumps to runs), `InternalCompilerBug`. Each is reported at the
  innermost form being compiled when it is raised (§4.6).

#### 4.5 Codegen invariants

- One routine per `fn*` in the source (plus the implicit
  top-level routine for any top-level form).
- Instructions are 64 bits. Operand indexes are 12 bits; the
  extension-instruction form is not emitted.
- The constant pool holds each Value once: identical Values (the
  same immediate, or the same heap object) share an entry. The
  var table is deduplicated the same way: a routine that
  references `x` twice carries one `V#` entry.
- Var references compile to `V#` operands bound to `*Var`
  pointers at compile time (§4.7).
- Upvalue slots in a closure are numbered 0..N; the closure
  captures a `[N]*UpvalCell` array at construction time.

- **Lowering rules for the primitive core**: §5.

#### 4.6 Spans

- Every Form carries the `SrcSpan` the reader assigned.
- A compile error is reported with the span of the innermost
  Form being lowered or compiled when the error is raised, or of
  the symbol lowering rejects (`LowerDiag.span`); the CLI renders
  it as `file:line:col`, the source line and a caret.
- Routines carry a span table (§8), so a runtime error reports
  the location of the instruction that raised it.

#### 4.7 Var linking

- **Input**: a `Tiny` tree + the current namespace (and the
  registry for qualified symbols).
- **Output**: routines whose `var_table` holds `*Var` pointers.

- **Responsibilities**:
  - `def` / `defn` intern the Var in the current namespace itself
    at compile time (possibly unbound until the form runs), never
    in a referred one: `(ns my.app) (defn inc ...)` binds
    `my.app/inc`, leaves `nexis.core/inc` as it was, and from then
    on a bare `inc` in `my.app` resolves to the local Var (rule 6
    finds it before the parent chain), as in Clojure. A symbol
    qualified with the current namespace's own name is its own
    Var, interned unbound when the definition is still to come.
  - Every Var reference is resolved to a `*Var` at compile time
    and stored in the routine's var table; the VM reads the Var's
    root at execution time, so forward references between
    top-level definitions work and redefinition is visible to
    already-compiled callers.
  - `(require ...)` is resolved by the expander through
    `src/loader.zig`: namespace name → `my/app/foo.nx` on the
    load path, cycle detection, an idempotent loaded set, and a
    check that the file declares the requested namespace.

---

### 5. Primitive core lowering

Exact bytecode semantics are in `docs/VM.md`; this section pins
what source forms lower to, in terms of opcode groups.

All examples assume emitted-code abstraction — actual opcode
variants are codegen details.

#### 5.1 `(quote x)`

- nil / booleans / fixnums use the ordinary `Tiny` variants
  (saves constant-pool entries).
- Symbols and keywords are interned to Values and placed in the
  constant pool.
- Compound collections are quoted element by element
  (`lowerQuotePayload`), so every element is a constant and the
  collection is one constant built at lowering (§4.4).
- A quote inside the payload is data: `'(a 'b)` is `(a (quote b))`,
  the 2-list `formToValue` renders a quote as. Syntax-quote,
  unquote, `@x`, `#(...)` and `^meta` inside a quoted form are
  `UnsupportedFeature`.
- Runtime: `mov:load-const`.

#### 5.2 `(if test then else?)`

- Lower `test` into an operand, read in place when it can be
  (§4.4).
- `jump:if-false` to `else-label` if the test is `false-or-nil`.
- Emit `then` code, leaving result in the result slot.
- `jump:jmp` to `end-label`, unless every path through `then`
  ends in `recur` or `throw`.
- `else-label`: emit `else` code (or `mov:load-nil` if
  `else` is absent).
- `end-label`: continuation.

#### 5.3 `(do expr...)`

- Lower each `expr` for its effect only; discard the result
  slot.
- The final `expr` lowers into the result slot of the `do`.
- `(do)` is nil, and so is every empty body: `(fn* [])`,
  `(let* [x 1])`, `(loop* [x 1])`, a `letfn*` binding without a
  body, a `try` body or handler with no forms. The literal `()`
  is the empty list, as `'()` is.

#### 5.4 `(let* [b1 v1 b2 v2 ...] body...)`

- Allocate a slot for each binding.
- Lower each `v` expression into the binding's slot in sequence
  (left-to-right); if the binding is captured (§6.1), emit
  `closure:box-local` on the slot immediately.
- Lower `body` as `do`.

#### 5.5 `(fn* name? [params... & rest?] body...)`

- Create a new routine for this `fn*`. Compile it recursively.
  The routine is registered in the **current** routine's
  constant pool as a `Const.routine` entry; its constant-pool
  index becomes operand A of the eventual `closure:make`.
- Compiling the body resolves each enclosing-frame local it
  references as a capture. For each, build a capture
  descriptor entry: `local_cell_slot(s)` if the captured
  binding is a local of the immediate enclosing frame,
  `inherited_upvalue(u)` if it is a capture inherited from an
  outer closure. Register the descriptor in the current routine's
  capture-descriptor table; its index becomes operand B.
- Emit `closure:make A=proto_const B=cap_desc C=result_slot`
  per `VM.md §6`. The result is a closure value (VALUE.md
  kind 24, `function`).
- The routine records `fixed_arity = params.len` and
  `variadic = rest != null`; the rest parameter is bound at slot
  `params.len` and the VM materializes the rest list at call
  time (`VM.md §6`). A captured rest parameter is boxed at
  function entry exactly like a captured fixed parameter.

**Named `fn*` self-name**:

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
cell is elided and `closure:make` is emitted with an empty
capture descriptor (zero sources).

**Compiler invariant**: code generated by the compiler never
introduces a user-code execution point between `closure:make`
and its matching `closure:init-cell`. The placeholder cell's
uninitialized state is therefore structurally invisible to user
code; hand-written bytecode that violates this surfaces
`:uninitialized-cell`.

- Multi-arity `(fn ([a] ...) ([a b] ...))` and multi-arity
  `defn` are expanded by the macroexpander into a single variadic
  `fn*` that dispatches on argument count; `fn*` itself takes a
  single parameter vector.

#### 5.6 `(recur args...)`

**Common skeleton** (both captured and non-captured cases):
- The arguments rebind the target's bindings with
  **parallel-assignment semantics**: every argument sees the
  bindings as they were before the `recur` (a naive sequential
  move corrupts `(loop* [a 1 b 2] (recur b a))`).
- An argument for a non-captured binding that no other argument
  mentions is computed straight into the binding's slot: nothing
  evaluated after it can observe the change.
- Every other argument is read in place when it is a constant,
  an upvalue or a slot no rebinding overwrites, and is computed
  into a fresh temporary otherwise; the moves into the binding
  slots follow once every argument is computed.
- Emit `jump:jmp` to the target's entry label.
- **Invariant**: no `call` opcode is emitted. Constant-stack
  guaranteed per PLAN §11.3.

**For non-captured loop bindings** (the common case):
- The slot move is the entire rebind.
- No heap allocation per iteration.

**For captured loop bindings** (semantically mandatory): the
`Emitter` emits cell-fresh-per-iteration, NOT cell mutation.
The canonical hazard is:

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
math:add          s_tmp, ...           ; the new value, in a fresh slot
closure:box-local s_tmp                ; s_tmp := fresh cell holding it
mov:move          s_binding_slot, s_tmp  ; install the fresh cell
jump:jmp          L_loop
```

The fresh cell is heap-allocated; this iteration cost is
**semantically required**, and the constant-heap-per-iteration
guarantee applies only to non-captured bindings. See `VM.md §11`
for the runtime-side phrasing.

`recur` does NOT use the U-store path (a store to `u:N` is
`UnimplementedOpcode`, `VM.md §6`). The fresh-cell pattern
above is the only mechanism.

`recur` inside a `fn*` body with no enclosing `loop*` targets
the function's own parameters: the `Emitter` installs a fn
`RecurTarget` after the captured-param boxing prelude, so the
rebind + jump re-enters the function body without a call
(constant-stack self-recursion). The target's bindings are the
fixed params followed, for a variadic `fn*`, by the rest slot:
`(recur a b s)` into `(fn* [a b & r] ...)` installs `s` in `r`'s
slot as it is, so the rest param receives whatever seq the `recur`
passes (Clojure's rule), and a `recur` that omits it is
`RecurArityMismatch`. A captured rest param gets a fresh cell per
iteration like any other binding. Overload clauses never reach
this path: the expander binds each clause's params through `loop`,
so a `recur` in a clause re-enters that clause with the clause's
own arity (`MACROEXPAND.md` §10, `fn`).

#### 5.6b `(letfn* [name1 (fn* ...) name2 (fn* ...) ...] body...)`

`letfn*` establishes mutually-recursive function bindings.
Unlike `let*`, all bindings on the LHS are visible to ALL
RHSs (and to the body), enabling functions to refer to each
other.

**Lowering** (mirrors `VM.md §6` `closure:new-cell` /
`closure:init-cell` discipline):

1. **Allocate placeholder cells**: for each binding `name_i`,
   emit `closure:new-cell s_name_i_cell`. After this step,
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
   step, each cell holds its final closure value, and all
   the closures observe each other through their captured cells.
5. **Lower body** as `do`. Body references to `name_i`
   resolve to the cells via the same capture machinery.

**Resolution invariant** (per §4.3 + this lowering): all
`letfn*` names are visible to ALL RHSs. The classic Clojure
example `(letfn [(even? [n] (if (zero? n) true (odd? (dec n))))
(odd? [n] (if (zero? n) false (even? (dec n))))] (even? 10))`
relies on this.

**Slot allocation**: the placeholder cell slots remain
live across the `closure:make` calls (per §4.4 capture-cell
liveness rule) AND across the `closure:init-cell` calls.

**Errors**: a `letfn*` body that calls a `name` BEFORE the
corresponding `init-cell` runs would surface
`:uninitialized-cell` at runtime. The lowering sequence above
(allocate-all → make-all → init-all) rules this out for
ordinary `letfn*` use.

#### 5.7 `(loop* [b1 v1 b2 v2 ...] body...)`

- Same as `let*` for binding setup (including boxing of
  captured bindings).
- The entry label is placed AFTER the box-local prelude.
- Lower `body` as `do`; `recur` within `body` targets the entry
  label with the binding slots as the target.

#### 5.8 `(def name expr?)`

- Intern `name` as a Var in the current namespace (creating
  one if absent).
- Lower `expr` (or `nil` if absent) into a result slot.
- Emit `var:store-var` V#(name), result-slot. The instruction
  sets the Var's root, marks it bound and yields the Var object.

`defn` is not a primitive: the host macro rewrites it to
`(def name (fn* name [params...] body...))` (MACROEXPAND.md), so
the body can recurse through the self-name without going through
the Var. Forward references between definitions work because each
`def` interns its Var at compile time and call-time resolution
through the var table picks up whatever is bound by then.

#### 5.9 `(var name)`, `(var ns/name)`

- Emit `var:var-object V#(name)` into a result slot. A bare
  name resolves as a symbol does (§4.3 rules 6-7); a qualified
  one exactly, as rule 5 resolves a qualified symbol.
- Returns the Var object itself (not its root value); used by
  macros and tooling. Does not trap on an unbound Var.

#### 5.10 `(try body... (catch any binding catch-body...)
    (finally finally-body...)?)`

The primitive takes exactly one `(catch any binding ...)` and an
optional `finally`; the expander lowers the surface form, with
any number of `(catch MATCHER b ...)` clauses, a keyword
matcher, or a `finally` alone, onto it (MACROEXPAND.md §10).

- `try` installs a handler via `ctrl:try-enter` (catch entry
  pc, binding slot, optional finally pc).
- `body` executes normally; `ctrl:try-exit` pops the handler on
  the normal path.
- On a throw, control transfers to the `catch` entry; the thrown
  value is bound to `binding`. The primitive's matcher is `any`;
  keyword matching is the expander's chain of
  `nexis.internal/#%catch-matches?` tests.
- `finally` runs on every exit path (normal, caught throw,
  uncaught throw, a rethrow from the handler). A throw inside
  `finally` replaces the pending one. The VM models this with a
  `FinallyContinuation` stack (`VM.md §12`).
- A thrown value is any value; there is no exception object, no
  stack trace and no cause chain. A keyword matcher `(catch :tag
  b ...)` takes a thrown value equal to `:tag`, a map whose
  `:error` entry is `:tag`, or an `ex-info` map whose data's
  `:error` is `:tag` (PLAN §6.4, Amendment Log).

#### 5.11 `(throw expr)`

- Lower `expr` into a slot.
- Emit `ctrl:throw` result-slot. Control transfers to the nearest
  handler (or exits the VM with `UncaughtThrow` and the value in
  `vm.unhandled_throw` if none).

---

### 6. Closure and upvalue contract

Captured-only boxing, descriptor-based construction, cell access
opcodes; §6.1 gives the discipline that makes the boxing decision
sound.

- A local is **captured** iff any nested `fn*` body references
  it. Lowering classifies it before the binding's code is
  emitted — see §6.1.
- **Non-captured locals**: plain frame slots. Read / write via
  SCVU slot operands. Zero per-op overhead.
- **Captured locals**: the bound value is wrapped in an
  `UpvalCell` (VM.md §6). The local's slot holds the **cell
  pointer**, not the direct value.
  - **Reads in the defining frame** use `closure:get-cell
    A=dst_slot B=cell_slot` to dereference and copy the
    cell's contents into a value slot. Plain slot operands
    do NOT auto-deref cells (making them do so would conflate
    cell-pointer storage with cell-content storage and break
    descriptor-based capture).
  - **Reads inside a child closure body** use the U operand
    kind on existing opcodes — e.g., `mov:move s0, u:0`,
    `math:add s0, u:0, c:1`. `resolve(u:N)` dereferences the
    cell automatically.
  - **Writes are forbidden** for captured locals: `set!` applies
    to dynamic Vars only, and a store to a `u:N` operand is
    `UnimplementedOpcode`; the
    only mechanism by which a captured loop-binding cell
    "changes" across iterations is the fresh-cell-per-iteration
    pattern documented in §5.6 — which allocates a NEW cell
    rather than mutating the existing one.
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
  (named `fn*` self-name) and §5.6b (`letfn*`).
- **Closure invocation**: the callee's frame is prepared with
  an upvalue pointer array copied from the closure; U#
  operands resolve via the callee frame's upvalue array.

#### 6.1 Capture marking, binding-time boxing

Lowering marks every captured binding; the `Emitter` emits
`closure:box-local` at **binding time** (or function entry for
captured params), making the runtime cell-vs-direct status of
each slot **provably stable across all control-flow paths**.

Boxing lazily — at the moment an inner closure first captures a
binding — is unsound under control flow: if the inner closure is
created in a branch (e.g., `(if false (fn* [] x) 0)`), the
`box-local` lives in the unreachable branch, while subsequent
same-frame reads emit `closure:get-cell` against an unboxed slot
— an `:expected-cell` trap on a valid program. Deciding before
the binding's code is emitted rules this out.

1. **Marking** (in lowering): `LowerEnv` mirrors every lexical
   scope the Emitter will have — `let*` / `loop*` bindings in
   order, `fn*` parameters (and the rest parameter), the `fn*`
   self-name (in the scope enclosing the body), `letfn*` names
   and the `catch` binding — each entry recording the `fn*`
   depth it was made at and pointing at its Tiny node's
   `captured` flag. Lowering a symbol finds its innermost
   binding; one made at a smaller depth than the symbol's is
   captured, and its flag is set. One pass, O(scope depth) per
   symbol.

2. **Binding-time boxing**: a `let*` / `loop*` binding, a
   parameter or a `catch` binding that is marked is boxed with
   `closure:box-local` as it is bound and pushed as
   `.cell_slot(s)`; every other binding is `.direct_slot(s)`.
   The instruction sits in straight-line code that every path
   reaching the binding's scope runs. A marked self-name gets a
   placeholder cell (§5.5).

3. **Same-frame read dispatch** (in `compileSymbol`):

   ```
   .direct_slot(s) → mov:move dst, slot(s)
   .cell_slot(s)   → closure:get-cell dst, slot(s)
   .upvalue(u)     → mov:move dst, u:u   (resolve(u) deref's the cell)
   ```

4. **Capture from parent scope** (in `resolveOrCapture`): when
   a child Emitter resolves a name to a parent-scope binding,
   the parent's binding is **already** `.cell_slot` (or an
   `.upvalue` further out), because lowering marked it. A
   `.direct_slot` result here is a compiler bug and is reported
   as `InternalCompilerBug`. Repeat references to the same
   captured name reuse one upvalue index.

5. **`BindingRef`** (`direct_slot`, `cell_slot`, `upvalue`) is
   **immutable from binding time onward**. There is no
   mid-codegen mutation of a binding's kind.

**Soundness invariant**:
> A binding is `.cell_slot` iff `closure:box-local` is emitted
> for its slot where it is bound (or at function entry for
> params, or at handler entry for a `catch` binding), which
> guarantees the slot holds an `UpvalCell*` on every reachable
> runtime path. `closure:get-cell` and `closure:make`'s
> `local_cell_slot` source can therefore use strict cell-only
> semantics with no runtime "ensure cell" dynamic check.

**Invariants** (continuation):
- `UpvalCell` and `Closure` are allocated on the VM's heap and
  collected like any other value (`VM.md §6`, `GC.md`).
- Closures carry references to cells, NOT copies of cell
  contents.
- A closure's captured-cell array is immutable after creation;
  only the cells' contents may change (through `init-cell`).

---

### 7. Error reporting

**Every error** raised by the compiler carries:

- A `CompileError` variant (`UnresolvedSymbol`,
  `RecurOutsideTail`, `MacroDepthExceeded`, ...). The variant
  set is the stable taxonomy; additions are non-breaking, renames
  are breaking. Full set: `UnsupportedForm`,
  `IntegerOutOfFixnumRange`, `ConstantPoolOverflow`,
  `JumpTargetOutOfRange`, `SlotOverflow`, `UnresolvedSymbol`,
  `DuplicateParam`, `DuplicateBinding`, `RecurOutsideTail`,
  `RecurArityMismatch`, `UnsupportedFeature`, `ReaderFailure`,
  `MalformedForm`, `MacroDepthExceeded`, `MacroExpansionFailure`,
  `RequiredFileFailed`, `ControlTransferred`, `ExpectedSymbol`,
  `ExpectedVector`, `InternalCompilerBug`, `StackOverflow`,
  `OutOfMemory`.
- A **primary SrcSpan** in `CompileOptions.out_span`: the span
  of the innermost form being lowered or emitted when the error
  was raised, or the symbol's own span for `UnresolvedSymbol`
  (the `LowerDiag` out-parameter); a macroexpansion error carries
  the top-level form's. Forms a macro produced carry the macro
  call's span (MACROEXPAND.md §4b), so an error inside an
  expansion is reported at the call.

Errors raised inside macro expansion are bucketed:
`MacroDepthExceeded` for depth, `MacroExpansionFailure` for
everything else (a malformed macro call, a macro returning a
non-Form, an integer literal out of range inside a macro
argument). `MalformedForm` / `ExpectedSymbol` / `ExpectedVector`
are lowering errors about special-form shape. `StackOverflow` is
a form nested deeper than the native stack's budget allows
lowering or emitting it: every recursive step of lowering, the
Emitter and `DeclaredNames` calls `stack.check` (VM.md §13.1), so
depth fails cleanly instead of faulting. Two variants are
not compile errors at all but the loader's run signals passed
through under their own names (MACROEXPAND.md §8):
`RequiredFileFailed`, a required file's form failed at run time
with no handler in force (the VM's `traced_error` and
`error_trace` carry it, and the CLI reports it as the runtime
error it is), and `ControlTransferred`, a required file's throw
that a handler in the running program took, which only `eval`
can see and which it returns as the VM signal of the same name.

There is no secondary span, no expansion-provenance chain and
no structured error value for compile errors the CLI reports. A
compile error inside `eval` is not reported by the CLI: the hook
throws the map `{:error :compile-error :message "<variant name>"
:form <the form>}` on the calling VM, a catchable value like any
other throw (MACROEXPAND.md §1.2 item 9); uncaught, it reaches
the CLI as `UncaughtThrow` with the map as its value. The CLI
prints

    nexis: <path>:<line>:<col>: <ErrorName>
        <source line>
        <caret under the span>

and exits 4 in `run`; the REPL prints the same with `<repl>` as
the path and reads the next line. A parse failure is reported the
same way at the token the parser stopped on (`parse error:
unexpected `)``, `unexpected end of input`), a reader failure at
the form the reader rejected with its kind and detail (`reader
error: :duplicate-literal-key (keyword :a)`); both exit 3.

A runtime error is reported at the instruction that raised it,
through the span table of §8: the same header, source line and
caret with `runtime error: <VmError name>` as the label (an
uncaught throw appends the thrown value as `pr-str` prints it),
then the frame chain the VM recorded (`VM.md` §13), innermost
first, one `at <name> (<path>:<line>:<col>)` line per frame:

    nexis: t.nx:2:4: runtime error: DivideByZero
        (/ 10 x))
         ^^^^^^
      at f (t.nx:2:4)
      at g (t.nx:4:14)
      at <top> (t.nx:6:2)

A `defn` or named `fn*` frame carries its name, an anonymous
closure is `fn`, a top-level form `<top>`, a form `eval` runs
`<eval>` (it has no source, so it is listed by name alone); a
caller frame's location is its call. `run` exits 5. The REPL reports under
`<repl>` and, since a line's definitions are called from later
lines, every line keeps its own source (`vm.SourceInfo`) for the
routines compiled from it.

---

### 8. SrcSpan threading

- Every Form has a `SrcSpan` from the reader (`Form.origin`).
- The macroexpander gives synthetic forms the macro call's span
  and keeps the source span of forms it passes through.
- Lowering reports the span of the symbol it rejects through
  `LowerDiag`; `compileFormWith` falls back to the form's.
- Lowering allocates every Tiny node as a `TinyNode{span, tiny}`
  and `lowerFormEnv` stamps the node with its Form's span; a
  node lowering synthesizes without a Form (the `do` around a
  body, the constant 1 of an inlined `inc`) has none and inherits the
  span of the form enclosing it. A hand-built `&Tiny{...}` tree
  compiles without spans (`compileTiny`).
- The Emitter attributes every instruction it emits to the span
  of the innermost node being compiled: `compileExpr` sets the
  current span on entry and restores the parent's on exit, so an
  instruction a parent emits after its children (`call:call`
  after the arguments, `call:return` after a body) carries the
  parent's span. `emit` grows a run-length table, one
  `SpanEntry{pc, span}` per change of span, ascending by pc.
- Each `Routine` carries that table (`spans`), the span of the
  form it was lowered from (`origin`) and the source the spans
  index into (`source`, a `vm.SourceInfo{path, text}` the
  caller of `compileFormWith` owns through `CompileOptions.source`);
  a nested closure prototype carries its own. Forms a macro
  produced carry the macro call's span, so instructions from an
  expansion resolve to the call. `Routine.spanAt(pc)` is a
  binary search; nothing reads the table while instructions
  execute (VM.md §5).
- A named `fn*` routine, which is what `defn` produces, carries
  its name (copied onto the compile allocator); an anonymous
  closure is `fn`.

---

### 9. Tests

Three layers:

#### 9.1 Unit tests per stage

- `src/expand.zig`: inline tests for recursive expansion,
  fixed-point termination, syntax-quote handling, `#(...)`
  lowering, host macros, `defmacro`, error cases.
- `src/compile.zig`: inline tests for what only the compiler
  sees: the error taxonomy (a table of malformed programs, each
  with its variant, and the span an error is reported at), the
  shape of the bytecode (one Var-table entry per Var, one upvalue
  per captured name, boxing of exactly the captured bindings on
  every path, `recur` in constant stack), routine limits, the span
  table, declared names and the stack guard.
- `src/vm.zig`: per-opcode tests on hand-assembled bytecode.

#### 9.2 Property tests

- `test/prop/compile.zig`: what programs evaluate to, as tables
  run through a program booted as `bin/nexis` boots one — source
  and printed value for every primitive-core form, binding and
  capture shape, `recur` target, quoted literal and the host
  macros the compiler relies on; source and error for compile and
  run failures — and randomized programs through the full
  pipeline: closure capture at nesting depth up to 10,
  syntax-quote output structurally equal to hand-built Forms,
  and random programs over arithmetic, `if`, shadowing `let*`,
  closures called in place and twice, and counting `loop*`s whose
  `recur` reads every binding (sometimes through a closure),
  whose compiled result must equal a reference evaluator's.

#### 9.3 Integration tests

- `test/integration/eval_pipeline.zig`: end-to-end source →
  result cases covering every primitive-core form, every host
  macro and every `try`/`catch`/`finally` exit path.
- `test/integration/runtime_polish.zig`: runtime behaviours
  across natives and the stdlib.
- `zig build examples` runs every `examples/*.nx` through
  `bin/nexis`; `zig build test` includes it.

#### 9.4 Guarantees the tests pin

1. Every primitive-core form compiles and executes per its
   documented semantics.
2. `recur` in a 10k-iteration loop runs in constant stack space:
   `VM.stack_high_water` and `VM.frame_high_water` (updated on
   grow operations only, so they record a true maximum) are
   unchanged across the loop.
3. Closure capture works across nesting depth 10.
4. `syntax-quote` / `unquote` / `unquote-splice` produce Forms
   structurally equal to hand-coded equivalents.
5. Compile errors carry a variant and a primary span.
6. `bench/main.zig`'s compiler category measures compilation
   throughput, eval throughput, closure-creation cost and
   `recur` per-iteration cost (`docs/PERF.md`).

---

### 10. Compilation entry points

The public surface of `src/compile.zig`:

- `compileFormWith(allocator, form, options)` — macroexpand, lower
  and emit one Form into a `Compiled` routine; `CompileOptions`
  carries the namespace, interner, host macro table, error-span
  out-parameter, persistent allocator (for `defmacro` closures),
  namespace registry, loader, declared names and source. The CLI,
  the loader and `eval` compile through it.
- `compileSourceWith(allocator, source, options)` — parse and read
  the first form of `source` (`parser.parseForm` +
  `Reader.readOneForm`), then `compileFormWith`.
- `compileTiny(allocator, tiny)` — a hand-built `Tiny` tree, with
  no namespace and no span table.
- `DeclaredNames` — the top-level names of a file or REPL line,
  collected before any of its forms compile (§4.3 rule #7).
- `RuntimeHooks` — the compiler as `macroexpand-1`, `read-string`
  and `eval` reach it at run time.

`compileSourceFull`, `compileSourceFullWithMacros` and
`compileSourceFullWithMacrosSpanPersistentRegistry` are positional
spellings of `compileSourceWith` for `bench/main.zig` and the eval
pipeline tests.

The CLI's file runner parses all top-level forms first
(`parser.parseProgram` + `Reader.readProgram`), then compiles and
runs each in turn, sharing the VM's namespace, interner and macro
table.

---

### 11. What's intentionally left flexible

- Exact Zig struct layouts for `Tiny`, `Compiled` and the
  `Emitter`. Spec the invariants they carry; let the
  implementation choose representations.
- Frame stack backing storage. `docs/VM.md` specs the logical
  frame model only.
- Exact dispatch-loop Zig code. `docs/VM.md` specs the contract.
- Exception-object mechanics beyond §5.10.

---

### 12. Cross-references

- `docs/VM.md` — bytecode format + runtime execution (companion).
- `docs/MACROEXPAND.md` — the Form → Form rewriter.
- `PLAN.md` §6 — primitive core vs macro-lowered forms.
- `PLAN.md` §11 — pipeline (higher-level than this doc).
- `PLAN.md` §12 — bytecode ISA (higher-level than `VM.md`).
- `docs/FORMS.md` — Form schema.
- `docs/SEMANTICS.md` — equality, hash, numeric edges
  (runtime-side; compiler must respect).
- `docs/VALUE.md` — heap kinds; `function` is kind 24.
- `docs/TOOLING.md` — what the §8 span table serves: located
  runtime errors and `nexis disasm`.
